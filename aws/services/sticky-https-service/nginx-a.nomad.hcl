# Sticky sessions POC, Option A (doc/STICKY_SESSIONS.md): nginx connects to the instances of
# sticky-https-service DIRECTLY (published host ports, bypassing API Gateway + mesh).
#
#   client → nginx :8443 (TLS termination, STICKY_ROUTE cookie, hash consistent)
#          → instance host port (HTTPS, from the Consul catalog)
#
# Test variant of infrastructure/nginx-rewrite: SAME job name, so "nomad job run" replaces the
# regular nginx in place (same host ports). Contains ONLY the sticky test route - other hostnames
# are not routed while it runs. Restore the regular nginx with:
#   nomad job run infrastructure/nginx-rewrite/job.nomad.hcl
#
# Run/restore: bin/instance/sticky_nginx_direct.sh

job "nginx-rewrite" {
  datacenters = ["dc1"]
  type        = "system"  # Runs on ALL nodes
  node_pool   = "all"

  group "nginx" {
    network {
      mode = "host"
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
          # Directory mount (not a single file): consul-template replaces the re-rendered file
          # (new inode), which a single-file bind mount would not see.
          "local/conf.d:/etc/nginx/nomad:ro",
        ]
      }

      # Consul token for the template below (reads the service catalog). Nomad exchanges this
      # identity for a Consul token via the nomad-workloads auth method (bootstrap_acl.sh); the
      # default task binding rule grants the nomad-default-tasks role (service read).
      # Without it, Consul ACLs silently FILTER the catalog → empty upstream (no error).
      identity {
        name = "consul_default"
        aud  = ["consul.io"]
        ttl  = "1h"
      }

      # Instance list from the Consul catalog. Re-rendered when instances change;
      # SIGHUP = graceful nginx reload.
      template {
        data          = <<EOF
upstream sticky_a {
    hash $sticky_route_key consistent;
{{- range service "sticky-https-service" }}
    server {{ .Address }}:{{ .Port }} max_fails=1 fail_timeout=10s;
{{- else }}
    server 127.0.0.1:1 down;   # service not deployed - keeps the nginx config valid
{{- end }}
}
EOF
        destination   = "local/conf.d/sticky-a-upstream.conf"
        change_mode   = "signal"
        change_signal = "SIGHUP"
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

    include /etc/nginx/nomad/sticky-a-upstream.conf;

    server {
        listen 8443 ssl;
        server_name sticky-a.example.com;

        ssl_certificate     /etc/nginx/tls/cert.pem;
        ssl_certificate_key /etc/nginx/tls/key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        location / {
            proxy_pass            https://sticky_a;
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
