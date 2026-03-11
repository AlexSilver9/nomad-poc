# Nginx with full end-to-end encryption.
#
# Traffic flow:
#   Client → ALB:443 (TLS terminate, ACM cert)
#          → nginx:8443 (HTTPS, self-signed cert — ALB re-encrypts here)
#          → Envoy:8080 (HTTP, plain HTTP services via mesh mTLS)
#          → Envoy:8082 (TCP, HTTPS-native services — nginx re-encrypts again)
#          → service container
#
# ALB setup: one HTTPS:8443 target group, no host-based rules needed.
# All hostname routing is handled by nginx server_name and Envoy hosts.
# Adding a new plain HTTP service requires zero changes here — only update the ingress gateway job.
# Adding a new HTTPS-native service requires one new server block below.

job "nginx-rewrite" {
  datacenters = ["dc1"]
  type        = "system"  # Runs on ALL nodes
  node_pool   = "all"

  group "nginx" {
    network {
      mode = "host"  # Required to bind to host port and reach Envoy at 127.0.0.1
    }

    # Generates a self-signed cert for the nginx HTTPS listener.
    # The ALB target group uses HTTPS:8443 and skips cert verification (self-signed is fine).
    # In production, replace with a cert from Vault PKI or ACM private CA.
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
          "apk add -q openssl && mkdir -p /alloc/tls && openssl req -x509 -newkey rsa:2048 -nodes -keyout /alloc/tls/key.pem -out /alloc/tls/cert.pem -days 3650 -subj '/CN=nomad-ingress' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1'",
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
          "../alloc/tls/cert.pem:/etc/nginx/tls/cert.pem:ro",
          "../alloc/tls/key.pem:/etc/nginx/tls/key.pem:ro",
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

    # Plain HTTP services (Envoy routes by Host header via HTTP listener on 8080)
    upstream envoy_http {
        server 127.0.0.1:8080;
    }

    # HTTPS-native services (Envoy TCP listener on 8082, nginx re-encrypts)
    upstream envoy_tcp {
        server 127.0.0.1:8082;
    }

    # business-service: needs URL rewrite, so gets an explicit block.
    # Must be declared before default_server so nginx matches server_name first.
    server {
        listen 8443 ssl;
        server_name business-service.example.com;

        ssl_certificate     /etc/nginx/tls/cert.pem;
        ssl_certificate_key /etc/nginx/tls/key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        # /download/<token> → /business-service/download.xhtml?token=<token>
        location ~ ^/download/(.*)$ {
            rewrite ^/download/(.*)$ /business-service/download.xhtml?token=$1 break;
            proxy_pass         http://envoy_http;
            proxy_http_version 1.1;
            proxy_set_header   Host $host;
            proxy_set_header   X-Real-IP $remote_addr;
            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto https;
        }

        location / {
            proxy_pass         http://envoy_http;
            proxy_http_version 1.1;
            proxy_set_header   Host $host;
            proxy_set_header   X-Real-IP $remote_addr;
            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto https;
        }
    }

    # https-service: HTTPS-native, re-encrypts to Envoy TCP listener.
    server {
        listen 8443 ssl;
        server_name https-service.example.com;

        ssl_certificate     /etc/nginx/tls/cert.pem;
        ssl_certificate_key /etc/nginx/tls/key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        # /download/<token> → /https-service/download.xhtml?token=<token>
        location ~ ^/download/(.*)$ {
            rewrite ^/download/(.*)$ /https-service/download.xhtml?token=$1 break;
            proxy_pass       https://envoy_tcp;
            proxy_ssl_verify off;  # Self-signed cert on the service side
        }

        location / {
            proxy_pass       https://envoy_tcp;
            proxy_ssl_verify off;
        }
    }

    # Default catch-all for all plain HTTP services.
    # Envoy routes by Host header — no nginx block needed per new service.
    server {
        listen 8443 ssl default_server;
        server_name _;

        ssl_certificate     /etc/nginx/tls/cert.pem;
        ssl_certificate_key /etc/nginx/tls/key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        location / {
            proxy_pass         http://envoy_http;
            proxy_http_version 1.1;
            proxy_set_header   Host $host;
            proxy_set_header   X-Real-IP $remote_addr;
            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto https;
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
