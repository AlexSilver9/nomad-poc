# Hazelcast Mesh Service
# POC: embedded-Hazelcast-style cluster (as used by Payara session replication) where all
# member-to-member traffic runs through the Consul service mesh (mTLS + intentions) instead of
# plain TCP on a published host port.
#
# Problem: every Hazelcast member must reach EVERY other member individually. A normal mesh
# upstream load-balances across all instances, so it cannot address one specific member.
#
# Solution: one virtual mesh service per member ordinal.
#   - Each alloc registers "hazelcast-mesh-service-hz" with tag hz-ordinal-<NOMAD_ALLOC_INDEX>
#   - service-resolver subsets select exactly one instance per ordinal (resolver.consul.hcl)
#   - redirect resolvers "hazelcast-mesh-service-hz-<N>" point at subset "member-<N>"
#     (resolver-member-<N>.consul.hcl)
#   - every alloc has one upstream per ordinal: 127.0.0.1:15700+N → member N (incl. itself)
#   - Hazelcast joins via TCP-IP member list 127.0.0.1:15700..157NN and advertises its own
#     public-address 127.0.0.1:15700+NOMAD_ALLOC_INDEX
#   Every alloc sees the same address → member mapping, so Hazelcast's member identities stay
#   consistent across the cluster.
#
# Security result:
#   - Hazelcast port 5701 is NOT published on the host - only reachable inside the
#     alloc's network namespace (i.e. by its own Envoy sidecar)
#   - The only way in is the sidecar's public listener, which requires a Consul-issued mTLS cert
#   - Intention hazelcast-mesh-service-hz → hazelcast-mesh-service-hz authorizes members
#   - No Consul ACL token needed in the job (no catalog-based Hazelcast discovery)
#
# Trade-off: member count is fixed. Changing var.members requires updating the resolver
# config entries (subsets + redirect resolvers) to match.
#
# Traffic flow (member 0 → member 1):
# hz(0) → 127.0.0.1:15701 → Envoy(0) upstream → mTLS → Envoy(1) public listener → hz(1):5701
#
# For the POC the Hazelcast member runs as its own task next to a dummy app task. Both share the
# alloc network namespace, which is equivalent to Payara + embedded Hazelcast in one process.
#
# Apply: see bin/instance/hazelcast_mesh.sh

variable "members" {
  type        = number
  description = "Number of Hazelcast members (= group count). Must match resolver config entries."
  default     = 3
}

variable "upstream_base_port" {
  type        = number
  description = "Local bind port for member 0. Member N is reachable at 127.0.0.1:<base + N>."
  default     = 15700
}

variable "revision" {
  type        = string
  description = "Bump (-var revision=2) to force a destructive rolling update in the test script."
  default     = "1"
}

job "hazelcast-mesh-service" {
  datacenters = ["dc1"]
  type        = "service"

  # Replace one member at a time: the old alloc is stopped before its replacement starts,
  # so two allocs with the same ordinal overlap only for the shutdown phase.
  update {
    max_parallel      = 1
    min_healthy_time  = "20s" # Give Hazelcast time to rejoin and migrate partitions
    healthy_deadline  = "3m"
    progress_deadline = "10m"
    auto_revert       = true
  }

  group "app" {
    count = var.members

    network {
      mode = "bridge"

      # Only the app port is published. Hazelcast (5701) is intentionally NOT listed here.
      port "http" {
        to = 8080
      }
    }

    # Application service (stands in for Payara HTTPS in production)
    service {
      name = "hazelcast-mesh-service"
      port = "http"

      check {
        type     = "http"
        path     = "/"
        interval = "10s"
        timeout  = "2s"
      }

      connect {
        sidecar_service {
          proxy {
            local_service_port = 8080
          }
        }
      }
    }

    # Hazelcast member service - mesh-only, no host port.
    # port = "5701" (numeric) registers the port inside the alloc's network namespace in Consul
    # (so the sidecar knows where to forward) without publishing it on the host.
    service {
      name = "hazelcast-mesh-service-hz"
      port = "5701"

      # Ordinal tag - the service-resolver subsets select exactly one instance per ordinal by it.
      # Must also be set on the sidecar (see sidecar_service below).
      tags = ["hz-ordinal-${NOMAD_ALLOC_INDEX}"]

      # Script check: Nomad runs curl inside the hazelcast container (own network namespace,
      # no host port needed). curl exit code 0 → passing, 1 → warning, other → critical.
      # "ready" = member active, NOT joined - intentional, see doc/HAZELCAST_MESH.md
      # (Health check scope).
      check {
        name     = "hazelcast-ready"
        type     = "script"
        task     = "hazelcast"
        command  = "curl"
        args     = ["-sf", "-o", "/dev/null", "http://127.0.0.1:5701/hazelcast/health/ready"]
        interval = "10s"
        timeout  = "3s"
      }

      connect {
        sidecar_service {
          # Consul evaluates subset filters against the SIDECAR registration (upstream endpoints
          # are queried with Connect=true, which returns proxy instances). Tags, not meta:
          # Nomad interpolates sidecar_service tags, but registers sidecar_service meta verbatim
          # (no ${NOMAD_ALLOC_INDEX} replacement) - verified in Nomad source.
          tags = ["hz-ordinal-${NOMAD_ALLOC_INDEX}"]

          proxy {
            local_service_port = 5701

            # One upstream per member ordinal (including this alloc's own ordinal).
            #
            # `dynamic` is HCL2 syntax that generates one `upstreams` block per element of
            # for_each, evaluated once at job submission (not at runtime). range(3) = [0, 1, 2],
            # and upstreams.value is the current element. For members = 3 this expands to:
            #
            #   upstreams { destination_name = "hazelcast-mesh-service-hz-0"  local_bind_port = 15700 }
            #   upstreams { destination_name = "hazelcast-mesh-service-hz-1"  local_bind_port = 15701 }
            #   upstreams { destination_name = "hazelcast-mesh-service-hz-2"  local_bind_port = 15702 }
            #
            # destination_name: a virtual service (not registered in the catalog). The redirect
            #   resolver hazelcast-mesh-service-hz-<N> (resolver-member-<N>.consul.hcl) sends it to
            #   subset member-<N> of hazelcast-mesh-service-hz, i.e. exactly the one alloc with
            #   NOMAD_ALLOC_INDEX = N.
            # local_bind_port: Envoy listens on 127.0.0.1:<port> inside this alloc's network
            #   namespace. Hazelcast connects there in plain TCP; Envoy carries it over mTLS to
            #   member N's sidecar.
            #
            # The ports must match the Hazelcast config below: member-list contains all of them,
            # public-address is the one for this alloc's own ordinal. Since every alloc gets the
            # same port → member mapping, all members agree on each other's addresses.
            # Own ordinal included: the group spec is identical for all allocs and the block is
            # expanded before NOMAD_ALLOC_INDEX is known, so it cannot skip its own ordinal.
            # Harmless - Hazelcast recognizes its own public-address in the member list and
            # does not connect to itself.
            dynamic "upstreams" {
              for_each = range(var.members)
              content {
                destination_name = "hazelcast-mesh-service-hz-${upstreams.value}"
                local_bind_port  = var.upstream_base_port + upstreams.value
              }
            }
          }
        }
      }
    }

    # Dummy application (stands in for Payara)
    task "app" {
      driver = "docker"

      config {
        image = "hashicorp/http-echo"
        args  = ["-text=hello from hazelcast-mesh-service", "-listen=:8080"]
        ports = ["http"]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    # Hazelcast member (stands in for Payara's embedded Hazelcast)
    task "hazelcast" {
      driver = "docker"

      # Allow a graceful shutdown (partition migration) before Nomad kills the container.
      kill_timeout = "30s"

      config {
        image = "hazelcast/hazelcast:5.5.0"
        volumes = [
          "local/hazelcast.yaml:/opt/hazelcast/config/hazelcast-mesh.yaml:ro",
        ]
      }

      env {
        HAZELCAST_CONFIG = "/opt/hazelcast/config/hazelcast-mesh.yaml"
        # GRACEFUL: migrate owned partitions to other members before shutdown (rolling updates)
        JAVA_OPTS = "-Dhazelcast.shutdownhook.policy=GRACEFUL -Dhazelcast.graceful.shutdown.max.wait=25"
        REVISION  = var.revision
      }

      # public-address and member-list use the mesh upstream addresses, never the container IP.
      # The member list is rendered from var.members at job submission (HCL), the own
      # public-address at runtime from NOMAD_ALLOC_INDEX (consul-template).
      template {
        destination = "local/hazelcast.yaml"
        data        = <<EOF
hazelcast:
  cluster-name: hazelcast-mesh-service
  network:
    public-address: 127.0.0.1:{{ env "NOMAD_ALLOC_INDEX" | parseInt | add ${var.upstream_base_port} }}
    port:
      port: 5701
      auto-increment: false
    rest-api:
      enabled: true
      endpoint-groups:
        HEALTH_CHECK:
          enabled: true
    join:
      auto-detection:
        enabled: false
      multicast:
        enabled: false
      tcp-ip:
        enabled: true
        member-list:
%{for i in range(var.members)~}
          - 127.0.0.1:${var.upstream_base_port + i}
%{endfor~}
EOF
      }

      resources {
        cpu    = 300
        memory = 512
      }
    }
  }
}
