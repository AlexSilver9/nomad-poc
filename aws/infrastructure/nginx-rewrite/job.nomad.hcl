job "nginx-rewrite" {
  datacenters = ["dc1"]
  type        = "system"  # Runs on ALL nodes
  node_pool   = "all"

  group "nginx" {
    network {
      mode = "host"  # Required to bind to host ports and reach API Gateway at 127.0.0.1
    }

    # Generates a self-signed cert for the HTTPS listener (:8443).
    # The ALB target group uses HTTPS:8443 and skips cert verification (self-signed is fine).
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

      # nginx sits between the ALB and the Consul API Gateway.
      #
      # HTTP flow  (port 8081 → API Gateway :8080):
      #   ALB :8081 → nginx :8081 → API Gateway :8080 → service sidecar → service
      #
      # HTTPS flow (port 8443 → API Gateway :8080 or :8082):
      #   ALB :8443 → nginx :8443 (TLS terminate) → API Gateway :8080 → service  (plain HTTP services)
      #   ALB :8443 → nginx :8443 (TLS terminate) → re-encrypt → API Gateway :8082 (TCP) → https-service
      #
      # Responsibility: hostname-based routing + regex URL rewrite with capture group.
      # nginx handles TLS termination on :8443, enabling HTTP-level routing and rewrites
      # that are not possible with TCP passthrough.
      #
      # Example:
      #   Client sends:   GET /download/abc123  Host: business-service.example.com
      #   nginx rewrites: GET /business-service/download.xhtml?token=abc123
      #   API Gateway receives rewritten path and routes to business-service by Host header.
      template {
        data = <<EOF
worker_processes auto;
error_log /dev/stderr info;

events {
    worker_connections 1024;
}

http {
    access_log /dev/stdout;

    upstream api_gateway_http {
        server 127.0.0.1:8080;
    }

    upstream api_gateway_https {
        server 127.0.0.1:8082;
    }

    # ─── HTTP :8081 ────────────────────────────────────────────────────────────

    # business-service: URL rewrite (HTTP).
    # Must be declared before default_server so nginx matches server_name first.
    server {
        listen 8081;
        server_name business-service.example.com;

        # /download/<token> → /business-service/download.xhtml?token=<token>
        location ~ ^/download/(.*)$ {
            rewrite ^/download/(.*)$ /business-service/download.xhtml?token=$1 break;
            proxy_pass         http://api_gateway_http;
            proxy_http_version 1.1;
            proxy_set_header   Host $host;
            proxy_set_header   X-Real-IP $remote_addr;
            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
        }

        location / {
            proxy_pass         http://api_gateway_http;
            proxy_http_version 1.1;
            proxy_set_header   Host $host;
            proxy_set_header   X-Real-IP $remote_addr;
            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
        }
    }

    # Default HTTP catch-all: pass any hostname through to API Gateway unchanged.
    server {
        listen 8081 default_server;
        server_name _;

        location / {
            proxy_pass         http://api_gateway_http;
            proxy_http_version 1.1;
            proxy_set_header   Host $host;
            proxy_set_header   X-Real-IP $remote_addr;
            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
        }
    }

    # ─── HTTPS :8443 (TLS termination + hostname routing) ──────────────────────

    # https-service: terminate client TLS, re-encrypt to API Gateway TCP :8082 → https-service.
    server {
        listen 8443 ssl;
        server_name https-service.example.com;

        ssl_certificate     /etc/nginx/tls/cert.pem;
        ssl_certificate_key /etc/nginx/tls/key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        location / {
            proxy_pass       https://api_gateway_https;
            proxy_ssl_verify off;  # Self-signed cert on the backend side
            proxy_set_header Host $host;
        }
    }

    # business-service: terminate client TLS, URL rewrite, forward HTTP to API Gateway :8080.
    server {
        listen 8443 ssl;
        server_name business-service.example.com;

        ssl_certificate     /etc/nginx/tls/cert.pem;
        ssl_certificate_key /etc/nginx/tls/key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        # /download/<token> → /business-service/download.xhtml?token=<token>
        location ~ ^/download/(.*)$ {
            rewrite ^/download/(.*)$ /business-service/download.xhtml?token=$1 break;
            proxy_pass         http://api_gateway_http;
            proxy_http_version 1.1;
            proxy_set_header   Host $host;
            proxy_set_header   X-Real-IP $remote_addr;
            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
        }

        location / {
            proxy_pass         http://api_gateway_http;
            proxy_http_version 1.1;
            proxy_set_header   Host $host;
            proxy_set_header   X-Real-IP $remote_addr;
            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
        }
    }

    # Default HTTPS catch-all: terminate TLS, forward HTTP to API Gateway :8080.
    server {
        listen 8443 ssl default_server;
        server_name _;

        ssl_certificate     /etc/nginx/tls/cert.pem;
        ssl_certificate_key /etc/nginx/tls/key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        location / {
            proxy_pass         http://api_gateway_http;
            proxy_http_version 1.1;
            proxy_set_header   Host $host;
            proxy_set_header   X-Real-IP $remote_addr;
            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
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
