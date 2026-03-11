job "nginx-rewrite" {
  datacenters = ["dc1"]
  type        = "system"  # Runs on ALL nodes
  node_pool   = "all"

  group "nginx" {
    network {
      mode = "host"  # Required to bind to host port and reach Envoy at 127.0.0.1
    }

    task "nginx" {
      driver = "docker"

      config {
        image        = "nginx:alpine"
        network_mode = "host"  # Bind directly to host network

        volumes = [
          "local/nginx.conf:/etc/nginx/nginx.conf:ro",
        ]
      }

      template {
        data = <<EOF
worker_processes auto;
error_log /dev/stderr info;

events {
    worker_connections 1024;
}

http {
    access_log /dev/stdout;

    upstream envoy_http {
        server 127.0.0.1:8080;
    }

    # business-service: explicit block for URL rewrite rules.
    # Must be declared before default_server so nginx matches server_name first.
    server {
        listen 8081;
        server_name business-service.example.com;

        # Route: /download/* with regex rewrite
        # Transforms: /download/<token> → /business-service/download.xhtml?token=<token>
        # e.g: /download/mytoken123 -> /business-service/download.xhtml?token=mytoken123
        location ~ ^/download/(.*)$ {
            # Rewrite and proxy (internal redirect, no 302)
            rewrite ^/download/(.*)$ /business-service/download.xhtml?token=$1 break;
            proxy_pass         http://envoy_http;
            proxy_http_version 1.1;
            proxy_set_header   Host $host;
            proxy_set_header   X-Real-IP $remote_addr;
            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
        }

        location / {
            proxy_pass         http://envoy_http;
            proxy_http_version 1.1;
            proxy_set_header   Host $host;
            proxy_set_header   X-Real-IP $remote_addr;
            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
        }
    }

    # Default catch-all: passes any hostname through to Envoy unchanged.
    # Envoy routes by Host header — no nginx block needed per new plain HTTP service.
    server {
        listen 8081 default_server;
        server_name _;

        location / {
            proxy_pass         http://envoy_http;
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
