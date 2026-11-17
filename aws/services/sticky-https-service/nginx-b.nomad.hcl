# Sticky sessions POC, Option B (doc/STICKY_SESSIONS.md): nginx addresses each instance via its OWN
# API Gateway TCP port (static config, no Consul access - like the production nginx).
#
#   client → nginx :8443 (TLS termination, STICKY_ROUTE cookie, hash consistent)
#          → API Gateway :8083 / :8084 → mTLS → instance 0 / 1
#
# Test variant of infrastructure/nginx-rewrite: SAME job name, so "nomad job run" replaces the
# regular nginx in place (same host ports). Contains ONLY the sticky test route - other hostnames
# are not routed while it runs. Restore the regular nginx with:
#   nomad job run infrastructure/nginx-rewrite/job.nomad.hcl
#
# Run/restore: bin/instance/sticky_gateway_ordinal.sh

job "nginx-rewrite" {
  datacenters = ["dc1"]
  type        = "system"  # Runs on ALL nodes
  node_pool   = "all"

  group "nginx" {
    network {
      mode = "host"  # Required to bind to host ports and reach API Gateway at 127.0.0.1
    }

    # Self-signed cert for the client-facing listener (same as nginx-rewrite)
    task "gen-cert" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      config {
        image        = "alpine"
        network_mode = "host"
        command      = "/bin/sh"
        args = [
          "-c",
          "apk add -q openssl && mkdir -p /alloc/tls && openssl req -x509 -newkey rsa:2048 -nodes -keyout /alloc/tls/key.pem -out /alloc/tls/cert.pem -days 3650 -subj '/CN=nginx-ingress' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1'",
        ]
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }

    task "nginx" {
      driver = "docker"

      config {
        image        = "nginx:alpine"
        network_mode = "host"

        volumes = [
          "local/nginx.conf:/etc/nginx/nginx.conf:ro",
          "../alloc/tls:/etc/nginx/tls:ro",
        ]
      }

      template {
        data        = <<EOF
worker_processes auto;
error_log /dev/stderr info;

events {
    worker_connections 1024;
}

http {
    access_log /dev/stdout;

    # nginx OSS has no "sticky" directive (nginx Plus only) → own route cookie + consistent hash.
    # Route key: the STICKY_ROUTE cookie, or a new random key ($request_id) on the first request.
    map $cookie_STICKY_ROUTE $sticky_route_key {
        ""      $request_id;
        default $cookie_STICKY_ROUTE;
    }
    # Set-Cookie only on the first request (add_header skips empty values).
    # Same $request_id as the hash key above → the cookie pins the client to the instance that
    # served this first request.
    map $cookie_STICKY_ROUTE $sticky_set_cookie {
        ""      "STICKY_ROUTE=$request_id; Path=/; Secure; HttpOnly";
        default "";
    }

    # One API Gateway TCP port per instance (gateway.consul.hcl listeners sticky-https-service-N).
    # A down instance → its gateway port has no endpoint and drops the connection →
    # proxy_next_upstream tries the other one; max_fails/fail_timeout skip it for 10s.
    upstream sticky_b {
        hash $sticky_route_key consistent;
        server 127.0.0.1:8083 max_fails=1 fail_timeout=10s;  # → instance 0
        server 127.0.0.1:8084 max_fails=1 fail_timeout=10s;  # → instance 1
    }

    server {
        listen 8443 ssl;
        server_name sticky-b.example.com;

        ssl_certificate     /etc/nginx/tls/cert.pem;
        ssl_certificate_key /etc/nginx/tls/key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        location / {
            proxy_pass            https://sticky_b;
            proxy_ssl_verify      off;  # Self-signed cert on the backend side
            proxy_set_header      Host $host;
            proxy_connect_timeout 2s;
            proxy_next_upstream   error timeout;
            add_header            Set-Cookie $sticky_set_cookie always;
        }
    }
}
EOF
        destination = "local/nginx.conf"
      }

      resources {
        cpu    = 100
        memory = 32
      }
    }
  }
}
