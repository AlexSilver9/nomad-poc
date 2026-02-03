# Business service
# Traffic flow:
#   ALB:443 → Traefik:443 → Ingress Gateway:8080 → Envoy Sidecar → business-service container
#
# This job deploys two services:
#   - business-service: handles default routes and /download
#   - business-service-api: handles /legacy-business-service/* routes
#
# The service-router (business-service-router.hcl) splits traffic by path.

job "business-service" {
  datacenters = ["dc1"]
  type        = "service"

  # Group for the main business-service
  group "business" {
    count = 2

    network {
      mode = "bridge"

      port "http" {
        to = 8080
      }
    }

    service {
      name = "business-service"
      port = "http"

      check {
        type     = "http"
        path     = "/"
        interval = "10s"
        timeout  = "2s"
      }

      connect {
        sidecar_service {
          proxy {
            local_service_port = 8080
          }
        }
      }
    }

    task "business" {
      driver = "docker"

      config {
        image = "containous/whoami"
        args  = ["--port=8080", "--name=business-service"]
        ports = ["http"]
      }

      resources {
        cpu    = 100
        memory = 32
      }
    }
  }

  # Group for the business-service-api
  group "business-api" {
    count = 2

    network {
      mode = "bridge"

      port "http" {
        to = 8080
      }
    }

    service {
      name = "business-service-api"
      port = "http"

      check {
        type     = "http"
        path     = "/"
        interval = "10s"
        timeout  = "2s"
      }

      connect {
        sidecar_service {
          proxy {
            local_service_port = 8080
          }
        }
      }
    }

    task "business-api" {
      driver = "docker"

      config {
        image = "containous/whoami"
        args  = ["--port=8080", "--name=business-service-api"]
        ports = ["http"]
      }

      resources {
        cpu    = 100
        memory = 32
      }
    }
  }
}
