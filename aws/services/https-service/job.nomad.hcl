# HTTPS Service
# Demonstrates end-to-end TLS: ALB terminates public TLS, re-encrypts to nginx on 8443,
# nginx proxies via TCP stream to Envoy TCP listener, Envoy forwards to this service over HTTPS.
#
# Traffic flow:
# Client → ALB:443 (TLS terminate) → nginx:8443 (HTTPS) → Envoy:8082 (TCP) → https-service:8443
#
# A prestart task generates a self-signed cert at startup and writes it to the shared alloc dir.
# In production, replace with Vault PKI secrets engine.

job "https-service" {
  datacenters = ["dc1"]
  type        = "service"

  group "app" {
    count = 2

    network {
      mode = "bridge"

      port "https" {
        to = 8443
      }
    }

    service {
      name = "https-service"
      port = "https"

      check {
        type            = "http"
        protocol        = "https"
        tls_skip_verify = true
        path            = "/"
        interval        = "15s"
        timeout         = "5s"
      }

      connect {
        sidecar_service {
          proxy {
            local_service_port = 8443
          }
        }
      }
    }

    # Prestart task: generate self-signed cert into the shared alloc dir before main task starts
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
          "apk add -q openssl && mkdir -p /alloc/tls && openssl req -x509 -newkey rsa:2048 -nodes -keyout /alloc/tls/key.pem -out /alloc/tls/cert.pem -days 3650 -subj '/CN=https-service.example.com' -addext 'subjectAltName=DNS:https-service.example.com,DNS:localhost'",
        ]
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }

    # Main task: nginx serving HTTPS using the cert from the shared alloc dir
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
worker_processes auto;
error_log /dev/stderr info;

events {
    worker_connections 1024;
}

http {
    access_log /dev/stdout;

    server {
        listen 8443 ssl;
        server_name https-service.example.com;

        ssl_certificate     /tls/cert.pem;
        ssl_certificate_key /tls/key.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        location / {
            return 200 "Hello from https-service (TLS end-to-end)\n";
            add_header Content-Type text/plain;
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
