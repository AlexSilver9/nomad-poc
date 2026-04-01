variable "admin_password" {
  type        = string
  description = "Grafana admin password"
}

variable "prometheus_addr" {
  type        = string
  description = "Prometheus address reachable from within the cluster, e.g. http://<node-ip>:9090"
}

job "grafana" {
  datacenters = ["dc1"]
  type        = "service"

  group "grafana" {
    count = 1

    network {
      mode = "host"

      port "grafana" {
        static = 3000
      }
    }

    volume "grafana-data" {
      type      = "host"
      source    = "grafana-data"
      read_only = false
    }

    task "grafana" {
      driver = "docker"

      config {
        image        = "grafana/grafana:11.6.0"
        network_mode = "host"

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
      template {
        data = <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    url: {{ env "PROMETHEUS_ADDR" }}
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
        PROMETHEUS_ADDR            = var.prometheus_addr
      }

      resources {
        cpu    = 200
        memory = 256
      }

      service {
        name = "grafana"
        port = "grafana"

        check {
          type     = "http"
          path     = "/api/health"
          interval = "15s"
          timeout  = "3s"
        }
      }
    }
  }
}
