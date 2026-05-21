# Consul API Gateway — Nomad job.
#
# The Consul API Gateway has no native Nomad jobspec integration.
# Nomad's gateway stanza only supports ingress, terminating, and mesh.
#
# Correct approach: two-task job using 'consul connect envoy -gateway api':
#   1. setup (prestart): Consul image registers the gateway and generates Envoy bootstrap config.
#   2. api (main):       Envoy image starts with the generated bootstrap config.
#
# Reference: https://developer.hashicorp.com/nomad/tutorials/integrate-consul/deploy-api-gateway-on-nomad
#
# ACL / Nomad Workload Identity (NWI):
#   The setup task declares an identity block (aud = ["consul.io"]). Nomad writes the signed
#   JWT to ${NOMAD_SECRETS_DIR}/consul_api_gateway — it does NOT automatically exchange it
#   for a Consul token. The setup command explicitly calls 'consul login' to exchange the
#   JWT for a scoped Consul token via the nomad-workloads auth method + builtin/api-gateway
#   binding rule, then passes the token to 'consul connect envoy' via CONSUL_HTTP_TOKEN.
#
#   The 'consul login' call falls back gracefully (|| true) so the job works even before
#   bootstrap_acl.sh is run. In that case CONSUL_HTTP_TOKEN="" → anonymous access → works
#   because default_policy = "allow" before enforce_acl.sh is run.
#
# Prerequisites:
#   - CNI plugins installed on all nodes (done by setup_nomad_aws_ami.sh)
#   - Consul API Gateway config entry written (infrastructure/api-gateway/gateway.consul.hcl)
#   - Routes written (services/<svc>/route.consul.hcl)
#   - For ACL: bootstrap_acl.sh must be run before enforce_acl.sh (sets up NWI + binding rule)
#
# Run: nomad job run infrastructure/api-gateway/job.nomad.hcl

job "api-gateway" {
  datacenters = ["dc1"]

  # system type: one allocation per node for HA (gateway runs on all 3 nodes)
  type = "system"

  group "gateway" {
    network {
      # bridge mode required for Consul Connect CNI
      mode = "bridge"

      # HTTP listener — all HTTP services share this port (routed by Host header via api-gateway)
      port "http" {
        static = 8080
        to     = 8080
      }

      # TCP listener — one port per HTTPS-native service (no Host header routing at TCP level)
      # https-service: 8082. Add a new port + listener in gateway.consul.hcl for each HTTPS service.
      port "https-service" {
        static = 8082
        to     = 8082
      }
    }

    # setup: registers the gateway with Consul and writes the Envoy bootstrap config to
    # NOMAD_ALLOC_DIR so the 'api' task can read it on startup.
    task "setup" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        # persistent: re-runs on every allocation restore (including node reboots), keeping Consul registration alive
        sidecar = true
      }

      # NWI: Nomad writes the JWT to ${NOMAD_SECRETS_DIR}/consul_api_gateway.
      # The command below explicitly exchanges it for a Consul token via consul login.
      # Falls back gracefully (|| true) when ACL is not yet bootstrapped.
      #
      # change_mode = "restart": safe here because sidecar = true means the task is long-running.
      # On JWT rotation (every 1h), Nomad restarts the sidecar container → re-runs consul login
      # with a fresh JWT → re-registers the service. The api task (Envoy) is not restarted.
      # NOTE: change_mode = "restart" with sidecar = false caused Alloc failures on JWT expiry
      # (Nomad tried to restart an already-exited prestart task. That problem applies to one-shot sidecars only.)
      identity {
        name        = "consul_api_gateway"
        aud         = ["consul.io"]
        ttl         = "1h"
        env         = true         # Exposes JWT as NOMAD_TOKEN_consul_api_gateway env var
        change_mode = "restart"    # Restart sidecar on JWT rotation so it re-authenticates and re-registers.
      }

      config {
        image   = "hashicorp/consul:1.22.7"
        command = "/bin/sh"
        args = [
          "-c",
          join(" && ", [
            "echo \"$NOMAD_TOKEN_consul_api_gateway\" > ${NOMAD_SECRETS_DIR}/nwi.jwt && consul login -method nomad-workloads -bearer-token-file ${NOMAD_SECRETS_DIR}/nwi.jwt -token-sink-file ${NOMAD_ALLOC_DIR}/consul.token || true",
            "export CONSUL_HTTP_TOKEN=$(cat ${NOMAD_ALLOC_DIR}/consul.token || echo '')",
            # sleep 2: Consul leader is on a different node (e.g. node 3). consul login
            # creates the token on the leader; on follower nodes the local ACL state machine
            # may not have applied the new Raft entry yet. Without the sleep, consul connect
            # envoy immediately uses the token and gets "ACL not found". 2 seconds give time for
            # replication to complete. Only follower server nodes are affected; client-only
            # nodes forward ACL validation to servers so they never see the stale state.
            "sleep 2",
            "consul connect envoy -gateway api -register -deregister-after-critical 10s -service ${NOMAD_JOB_NAME} -admin-bind 0.0.0.0:19000 -bootstrap > ${NOMAD_ALLOC_DIR}/envoy_bootstrap.json",
            # keep sidecar alive; Nomad restarts it on JWT rotation and allocation restore
            "sleep infinity"
          ])
        ]
      }

      env {
        # Node IP (not 127.0.0.1) is required: bridge networking containers cannot
        # reach the host loopback. attr.unique.network.ip-address is the node's primary IP.
        CONSUL_HTTP_ADDR = "http://${attr.unique.network.ip-address}:8500"
        # Port 8502 (plain gRPC): consul connect envoy -bootstrap generates the local_agent
        # cluster with http2_protocol_options (no TLS). Port 8503 is TLS — plain HTTP/2 to
        # a TLS port causes immediate connection termination in Envoy.
        # Rule: everything uses 8502. Port 8503 is for consul CLI's own TLS session only.
        CONSUL_GRPC_ADDR = "${attr.unique.network.ip-address}:8502"
      }

      resources {
        cpu        = 50
        memory     = 64
        memory_max = 128
      }
    }

    # api: runs the Envoy proxy using the bootstrap config generated by 'setup'.
    # Version must be compatible with the installed Consul version (1.22.x → Envoy 1.30+).
    # Keep in sync with the Envoy version Nomad uses for Connect sidecars on this cluster.
    task "api" {
      driver = "docker"

      config {
        image   = "envoyproxy/envoy:v1.35.8"
        command = "/bin/sh"
        args = [
          "-c",
          # Wait for setup sidecar to write bootstrap.json before starting Envoy.
          # On allocation restore, bootstrap.json from the previous run is already present
          # so the wait exits immediately. On first start, setup sidecar writes it within some seconds.
          "until [ -s ${NOMAD_ALLOC_DIR}/envoy_bootstrap.json ]; do sleep 1; done && exec envoy --config-path ${NOMAD_ALLOC_DIR}/envoy_bootstrap.json --log-level info --concurrency 2 --disable-hot-restart"
        ]
      }

      resources {
        cpu        = 100
        memory     = 64
        memory_max = 64
      }
    }
  }
}
