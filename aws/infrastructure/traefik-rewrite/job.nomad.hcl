job "traefik-rewrite" {
  datacenters = ["dc1"]
  type        = "system"  # Runs on ALL nodes
  node_pool   = "all"

  group "traefik" {
    network {
      mode = "host"  # Required to bind to host port 8081 and reach API Gateway at 127.0.0.1:8080
    }

    task "traefik" {
      driver = "docker"

      config {
        image        = "traefik:v3.0"
        network_mode = "host"  # Bind directly to host network

        args = [
          "--entrypoints.web.address=:8081",
          "--providers.file.filename=/etc/traefik/dynamic.yaml",
          "--log.level=INFO",
        ]

        volumes = [
          "local/dynamic.yaml:/etc/traefik/dynamic.yaml",
        ]
      }

      # Traefik sits between the ALB and the Consul API Gateway.
      #
      # Flow:  ALB :8081 → Traefik :8081 → API Gateway :8080 → service sidecar → service
      #
      # Responsibility: regex URL rewrite with capture group.
      # The API Gateway's URLRewrite.Path only supports full-path replacement.
      # Traefik handles this before the request reaches the API Gateway.
      #
      # Example:
      #   Client sends:   GET /legacy-download/abc123  Host: business-service.example.com
      #   Traefik rewrites to: GET /business-service/download.xhtml/abc123
      #   API Gateway receives the rewritten path and routes to business-service.
      #
      # The Host header is forwarded unchanged (passHostHeader = true) so the API Gateway
      # can still perform hostname-based routing.
      template {
        data = <<EOF
http:
  routers:
    # /download/<token> → /business-service/download.xhtml?token=<token>
    # Regex rewrite: captures the token and converts it to a query parameter.
    # Priority 10 — evaluated before the catch-all passthrough below.
    download-rewrite:
      rule: "PathPrefix(`/download`)"
      entryPoints:
        - web
      middlewares:
        - download-rewrite
      service: api-gateway
      priority: 10

    # All other traffic: forward to the API Gateway unchanged.
    # The Host header is preserved so hostname-based routing works at the gateway.
    passthrough:
      rule: "PathPrefix(`/`)"
      entryPoints:
        - web
      service: api-gateway
      priority: 1

  middlewares:
    download-rewrite:
      replacePathRegex:
        # Captures the token and rewrites to a query parameter.
        # Note: replacePathRegex does not URL-encode '?' — safe for path-to-query rewrite.
        regex: "^/download/(.*)"
        replacement: "/business-service/download.xhtml?token=$${1}"

  services:
    api-gateway:
      loadBalancer:
        passHostHeader: true  # Preserve Host header for API Gateway hostname routing
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
