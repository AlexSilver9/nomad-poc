job "traefik-rewrite" {
  datacenters = ["dc1"]
  type        = "system"  # Runs on ALL nodes

  group "traefik" {
    network {
      mode = "host"  # Required to bind to host port 443 and reach Envoy at 127.0.0.1:8080
    }

    task "traefik" {
      driver = "docker"

      config {
        image        = "traefik:v3.0"
        network_mode = "host"  # Bind directly to host network

        args = [
          "--entrypoints.web.address=:443",
          "--providers.file.filename=/etc/traefik/dynamic.yaml",
          "--log.level=DEBUG",  # Helpful for debugging
        ]

        volumes = [
          "local/dynamic.yaml:/etc/traefik/dynamic.yaml",
        ]
      }

      template {
        data = <<EOF
http:
  routers:
    # Route: /download/* with regex rewrite (business-service host)
    download-rewrite:
      rule: "Host(`business-service`) && PathPrefix(`/download`)"
      entryPoints:
        - web
      middlewares:
        - download-to-query
      service: envoy-ingress
      priority: 10

    # Route: business-service host passthrough
    business-passthrough:
      rule: "Host(`business-service`)"
      entryPoints:
        - web
      service: envoy-ingress
      priority: 5

    # Default: catch-all for any other traffic (e.g., Host: localhost)
    default-passthrough:
      rule: "PathPrefix(`/`)"
      entryPoints:
        - web
      service: envoy-ingress
      priority: 1

  middlewares:
    download-to-query:
      replacePathRegex:
        regex: "^/download/(.*)$"
        replacement: "/business-service/download.xhtml?token=$1"

  services:
    envoy-ingress:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:8080"
EOF
        destination = "local/dynamic.yaml"
      }

      resources {
        cpu    = 100
        memory = 32
      }
    }
  }
}
