variable "admin_password" {
  type        = string
  description = "Grafana admin password"
}

variable "grafana_tech_admin_password" {
  type        = string
  description = "Password for the tech-admin user (Admin role). Set by setup_monitoring.sh. Leave empty (default) to skip user creation."
  default     = ""
}

variable "grafana_tech_editor_password" {
  type        = string
  description = "Password for the tech-editor user (Editor role). Set by setup_monitoring.sh. Leave empty (default) to skip user creation."
  default     = ""
}

variable "grafana_tech_viewer_password" {
  type        = string
  description = "Password for the tech-viewer user (Viewer role). Set by setup_monitoring.sh. Leave empty (default) to skip user creation."
  default     = ""
}

job "grafana" {
  datacenters = ["dc1"]
  type        = "service"

  group "grafana" {
    count = 1

    network {
      mode = "bridge"

      port "http" {
        to = 3000
      }
    }

    volume "grafana-data" {
      type      = "host"
      source    = "grafana-data"
      read_only = false
    }

    # Service block at group level — required for Consul Connect sidecar.
    # Declares an upstream to Prometheus so Grafana can reach it at localhost:9091
    # regardless of which node Prometheus is scheduled on.
    service {
      name = "grafana"
      port = "http"

      check {
        type     = "http"
        path     = "/api/health"
        interval = "15s"
        timeout  = "3s"
      }

      connect {
        sidecar_service {
          proxy {
            local_service_port = 3000

            upstreams {
              destination_name = "prometheus"
              local_bind_port  = 9091
            }
          }
        }
      }
    }

    task "grafana" {
      driver = "docker"

      config {
        image = "grafana/grafana:11.6.0"

        volumes = [
          "local/provisioning/datasources:/etc/grafana/provisioning/datasources:ro",
        ]
      }

      volume_mount {
        volume      = "grafana-data"
        destination = "/var/lib/grafana"
        read_only   = false
      }

      # Provisions Prometheus as the default datasource at startup.
      # Uses localhost:9091 — the sidecar upstream port — so Grafana always reaches
      # Prometheus via the service mesh regardless of which node it runs on.
      template {
        data = <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    url: http://localhost:9091
    isDefault: true
    editable: false
EOF
        destination = "local/provisioning/datasources/prometheus.yml"
      }

      env {
        GF_SERVER_HTTP_PORT        = "3000"
        GF_AUTH_ANONYMOUS_ENABLED  = "false"
        GF_SECURITY_ADMIN_PASSWORD = var.admin_password
        GF_PATHS_PROVISIONING      = "/etc/grafana/provisioning"

        # Tech user passwords — used by setup_monitoring.sh to create users via the
        # Grafana HTTP API after startup. Grafana OSS does not support user provisioning
        # via config files; users must be created via API.
        GRAFANA_TECH_ADMIN_PASSWORD  = var.grafana_tech_admin_password
        GRAFANA_TECH_EDITOR_PASSWORD = var.grafana_tech_editor_password
        GRAFANA_TECH_VIEWER_PASSWORD = var.grafana_tech_viewer_password
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }
  }
}
