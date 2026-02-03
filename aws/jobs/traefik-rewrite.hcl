job "traefik-rewrite" {
  datacenters = ["dc1"]
  type        = "system"  # Runs on ALL nodes

  group "traefik" {
    network {
      port "https" {
        static = 443  # ALB targets this port on all instances
      }
    }

    task "traefik" {
      driver = "docker"

      config {
        image = "traefik:v3.0"
        ports = ["https"]

        args = [
          "--entrypoints.https.address=:443",
          "--providers.file.filename=/etc/traefik/dynamic.yaml",
        ]

        volumes = [
          "local/dynamic.yaml:/etc/traefik/dynamic.yaml",
        ]
      }

      template {
        data = <<EOF
http:
  routers:
    download-rewrite:
      rule: "Host(`business-service`) && PathPrefix(`/download`)"
      middlewares:
        - download-to-query
      service: envoy-ingress
      priority: 10

    passthrough:
      rule: "Host(`business-service`)"
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
          - url: "http://127.0.0.1:8080"  # Local Envoy ingress gateway
EOF
        destination = "local/dynamic.yaml"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
