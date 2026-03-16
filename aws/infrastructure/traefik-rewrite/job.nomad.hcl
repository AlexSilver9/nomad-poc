job "traefik-rewrite" {
  datacenters = ["dc1"]
  type        = "system"  # Runs on ALL nodes
  node_pool   = "all"

  group "traefik" {
    network {
      mode = "host"  # Required to bind to host ports and reach API Gateway at 127.0.0.1
    }

    # Generates a self-signed cert for the HTTPS listener (:8443).
    # The ALB target group uses HTTPS:8443 and skips cert verification (self-signed is fine).
    # In production, replace with a cert from Vault PKI or a CA-signed cert.
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

    task "traefik" {
      driver = "docker"

      config {
        image        = "traefik:v3.0"
        network_mode = "host"

        args = [
          "--entrypoints.web.address=:8081",
          "--entrypoints.websecure.address=:8443",
          "--providers.file.filename=/etc/traefik/dynamic.yaml",
          "--log.level=INFO",
        ]

        volumes = [
          "local/dynamic.yaml:/etc/traefik/dynamic.yaml",
          "../alloc/tls:/local/tls:ro",
        ]
      }

      # Traefik sits between the ALB and the Consul API Gateway.
      #
      # HTTP flow  (port 8081 → API Gateway :8080):
      #   ALB :8081 → Traefik :8081 → API Gateway :8080 → service sidecar → service
      #
      # HTTPS flow (port 8443 → API Gateway :8082):
      #   ALB :8443 → Traefik :8443 (TLS terminate) → re-encrypt → API Gateway :8082 (TCP) → service
      #
      # Responsibility: regex URL rewrite with capture group.
      # The API Gateway's URLRewrite.Path only supports full-path replacement.
      # Traefik handles this before the request reaches the API Gateway.
      #
      # Example:
      #   Client sends:   GET /download/abc123  Host: business-service.example.com
      #   Traefik rewrites to: GET /business-service/download.xhtml?token=abc123
      #   API Gateway receives the rewritten path and routes to business-service by Host header.
      #
      # The Host header is forwarded unchanged (passHostHeader = true) so the API Gateway
      # can still perform hostname-based routing.
      template {
        data = <<EOF
tls:
  certificates:
    - certFile: /local/tls/cert.pem
      keyFile:  /local/tls/key.pem

http:
  routers:
    # -------------------------------------------------------------------------
    # HTTP entrypoint (:8081) — plain HTTP services via API Gateway :8080
    # -------------------------------------------------------------------------

    # /download/<token> → /business-service/download.xhtml?token=<token>
    # Priority 10 — evaluated before the catch-all passthrough below.
    download-rewrite:
      rule: "PathPrefix(`/download`)"
      entryPoints:
        - web
      middlewares:
        - download-rewrite
      service: api-gateway-http
      priority: 10

    # All other HTTP traffic: forward to the API Gateway unchanged.
    passthrough:
      rule: "PathPrefix(`/`)"
      entryPoints:
        - web
      service: api-gateway-http
      priority: 1

    # -------------------------------------------------------------------------
    # HTTPS entrypoint (:8443) — TLS termination + same rewrite rules
    # -------------------------------------------------------------------------

    # https-service: HTTPS-native backend. Re-encrypt and forward to API Gateway TCP :8082.
    # Priority 20 — must match before the download-rewrite-secure catch-all below.
    https-service-secure:
      rule: "Host(`https-service.example.com`)"
      entryPoints:
        - websecure
      tls: {}
      service: api-gateway-tcp
      priority: 20

    # /download/<token> on any other host → rewrite, then forward HTTP to API Gateway :8080.
    download-rewrite-secure:
      rule: "PathPrefix(`/download`)"
      entryPoints:
        - websecure
      middlewares:
        - download-rewrite
      tls: {}
      service: api-gateway-http
      priority: 10

    # All other HTTPS traffic: forward HTTP to API Gateway :8080.
    passthrough-secure:
      rule: "PathPrefix(`/`)"
      entryPoints:
        - websecure
      tls: {}
      service: api-gateway-http
      priority: 1

  middlewares:
    download-rewrite:
      replacePathRegex:
        # Captures the token and rewrites to a query parameter.
        regex: "^/download/(.*)"
        replacement: "/business-service/download.xhtml?token=$${1}"

  services:
    # Plain HTTP to API Gateway HTTP listener
    api-gateway-http:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://127.0.0.1:8080"

    # Re-encrypted HTTPS to API Gateway TCP listener (TCP passthrough to HTTPS-native backend)
    api-gateway-tcp:
      loadBalancer:
        passHostHeader: true
        serversTransport: skip-verify
        servers:
          - url: "https://127.0.0.1:8082"

  serversTransports:
    skip-verify:
      insecureSkipVerify: true  # Self-signed cert on the backend side
EOF
        destination = "local/dynamic.yaml"
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
