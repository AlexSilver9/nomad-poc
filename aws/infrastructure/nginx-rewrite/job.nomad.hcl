job "nginx-rewrite" {
  datacenters = ["dc1"]
  type        = "system"  # Runs on ALL nodes
  node_pool   = "all"

  group "nginx" {
    network {
      mode = "host"  # Required to bind to host port 8081 and reach Envoy at 127.0.0.1:8080
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

    # Upstream: Envoy ingress gateway
    upstream envoy_ingress {
        server 127.0.0.1:8080;
    }

    server {
        # Plain HTTP on port 8081
        listen 8081 default_server;
        server_name business-service;

        # Route: /download/* with regex rewrite
        # Transforms: /download/mytoken123 -> /business-service/download.xhtml?token=mytoken123
        location ~ ^/download/(.*)$ {
            # Rewrite and proxy (internal redirect, no 302)
            rewrite ^/download/(.*)$ /business-service/download.xhtml?token=$1 break;
            proxy_pass http://envoy_ingress;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # Default: passthrough to Envoy
        location / {
            proxy_pass http://envoy_ingress;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
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
