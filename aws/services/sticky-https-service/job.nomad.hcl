# Sticky HTTPS Service
# POC: sticky sessions for HTTPS-native services (Payara) without session replication.
# See doc/STICKY_SESSIONS.md.
#
# Two independent instances serving HTTPS (nginx with a self-signed cert stands in for Payara).
# The response names the instance: "Name: sticky-<alloc index>" + "Hostname: <container>".
#
# Used by both test options - nginx does the stickiness (test variants of nginx-rewrite):
#   A (bin/instance/sticky_nginx_direct.sh):    nginx-a.nomad.hcl → instance host port directly
#                                               (bypasses mesh)
#   B (bin/instance/sticky_gateway_ordinal.sh): nginx-b.nomad.hcl → API Gateway port per instance (8083/8084)
#                                               → mTLS → instance (resolver subset by ordinal tag)
#
# Apply: see the test scripts above

job "sticky-https-service" {
  datacenters = ["dc1"]
  type        = "service"

  update {
    max_parallel      = 1
    min_healthy_time  = "10s"
    healthy_deadline  = "2m"
    progress_deadline = "5m"
    auto_revert       = true
  }

  group "app" {
    count = 2

    network {
      mode = "bridge"

      # Published dynamic host port: Option A connects here directly.
      port "https" {
        to = 8443
      }
    }

    service {
      name = "sticky-https-service"
      port = "https"

      # Ordinal tag - Option B's service-resolver subsets select one instance per ordinal by it
      # (resolver.consul.hcl). Also set on the sidecar: Consul evaluates subset filters against the
      # sidecar registration (same as hazelcast-mesh-service).
      tags = ["ordinal-${NOMAD_ALLOC_INDEX}"]

      check {
        type            = "http"
        protocol        = "https"
        tls_skip_verify = true
        path            = "/"
        interval        = "10s"
        timeout         = "3s"
      }

      connect {
        sidecar_service {
          tags = ["ordinal-${NOMAD_ALLOC_INDEX}"]
          proxy {
            local_service_port = 8443
          }
        }
        # Nomad's default sidecar resources (cpu 250, memory 300) are far too large for the POC nodes.
        sidecar_task {
          resources {
            cpu    = 50
            memory = 48
          }
        }
      }
    }

    # Prestart task: self-signed cert into the shared alloc dir (same as https-service)
    task "gen-cert" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      config {
        image   = "alpine"
        command = "/bin/sh"
        args = [
          "-c",
          "apk add -q openssl && mkdir -p /alloc/tls && openssl req -x509 -newkey rsa:2048 -nodes -keyout /alloc/tls/key.pem -out /alloc/tls/cert.pem -days 3650 -subj '/CN=sticky-https-service' -addext 'subjectAltName=DNS:localhost'",
        ]
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }

    # HTTPS app (stands in for Payara)
    task "app" {
      driver = "docker"

      config {
        image = "nginx:alpine"
        volumes = [
          "local/nginx.conf:/etc/nginx/nginx.conf:ro",
          "../alloc/tls/cert.pem:/tls/cert.pem:ro",
          "../alloc/tls/key.pem:/tls/key.pem:ro",
        ]
      }

      template {
        data        = <<EOF
worker_processes 1;
error_log /dev/stderr info;

events {
    worker_connections 256;
}

http {
    access_log /dev/stdout;

    server {
        listen 8443 ssl;

        ssl_certificate     /tls/cert.pem;
        ssl_certificate_key /tls/key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        location / {
            default_type text/plain;
            return 200 "Name: sticky-{{ env "NOMAD_ALLOC_INDEX" }}\nHostname: $hostname\n";
        }
    }
}
EOF
        destination = "local/nginx.conf"
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }
  }
}
