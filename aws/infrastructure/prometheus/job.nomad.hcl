variable "nomad_scrape_token" {
  type        = string
  description = "Nomad ACL token for scraping /v1/metrics. Set automatically by setup_monitoring.sh when ACL is enforced. Leave empty (default) when ACL is not enforced."
  default     = ""
}

variable "consul_token" {
  type        = string
  description = "Consul ACL token for service discovery. Set automatically by setup_monitoring.sh when ACL is enforced. Leave empty (default) when ACL is not enforced."
  default     = ""
}

variable "prometheus_admin_hash" {
  type        = string
  description = "bcrypt hash of the Prometheus admin password. Set by setup_monitoring.sh. Leave empty (default) to disable basic auth."
  default     = ""
}

variable "prometheus_tech_hash" {
  type        = string
  description = "bcrypt hash of the shared Prometheus tech user password. Set by setup_monitoring.sh. Leave empty (default) to disable basic auth."
  default     = ""
}

job "prometheus" {
  datacenters = ["dc1"]
  type        = "service"

  group "prometheus" {
    count = 1

    network {
      mode = "bridge"

      port "http" {
        to = 9090
      }
    }

    volume "prometheus-data" {
      type      = "host"
      source    = "prometheus-data"
      read_only = false
    }

    # Service block at group level — required for Consul Connect sidecar.
    service {
      name = "prometheus"
      port = "http"

      check {
        type     = "http"
        path     = "/-/healthy"
        interval = "15s"
        timeout  = "3s"
      }

      connect {
        sidecar_service {
          proxy {
            local_service_port = 9090
          }
        }
      }
    }

    task "prometheus" {
      driver = "docker"

      config {
        image = "prom/prometheus:v3.2.1"

        args = [
          "--config.file=/local/prometheus.yml",
          "--storage.tsdb.path=/prometheus",
          "--web.config.file=/local/web.yml",
        ]
      }

      volume_mount {
        volume      = "prometheus-data"
        destination = "/prometheus"
        read_only   = false
      }

      # Generates prometheus.yml using Consul service discovery to find Nomad nodes.
      # Nomad agents register themselves in Consul as 'nomad' (servers) and 'nomad-client' (clients).
      # Uses CONSUL_ADDR (node IP) instead of localhost — bridge mode containers cannot reach host loopback.
      # Auth blocks are omitted when tokens are empty (ACL not enforced).
      template {
        data = <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'nomad'
    metrics_path: /v1/metrics
    params:
      format: [prometheus]
{{ if env "NOMAD_SCRAPE_TOKEN" }}
    authorization:
      credentials: {{ env "NOMAD_SCRAPE_TOKEN" }}
{{ end }}
    consul_sd_configs:
      - server: '{{ env "CONSUL_ADDR" }}'
{{ if env "CONSUL_HTTP_TOKEN" }}
        token: '{{ env "CONSUL_HTTP_TOKEN" }}'
{{ end }}
        services:
          - nomad
          - nomad-client
    relabel_configs:
      # Replace the Consul-provided port with Nomad's HTTP port
      - source_labels: [__address__]
        regex: '(.*):.*'
        replacement: '$1:4646'
        target_label: __address__
      - source_labels: [__meta_consul_node]
        target_label: instance
      - source_labels: [__meta_consul_service]
        target_label: job
EOF
        destination = "local/prometheus.yml"
      }

      # Generates web.yml for Prometheus native basic auth.
      # When hashes are empty the file has no users — Prometheus starts without auth.
      template {
        data = <<EOF
basic_auth_users:
{{ if env "PROMETHEUS_ADMIN_HASH" }}
  admin: '{{ env "PROMETHEUS_ADMIN_HASH" }}'
{{ end }}
{{ if env "PROMETHEUS_TECH_HASH" }}
  tech: '{{ env "PROMETHEUS_TECH_HASH" }}'
{{ end }}
EOF
        destination = "local/web.yml"
      }

      env {
        # Node IP used for Consul SD — bridge mode containers cannot reach host loopback
        CONSUL_ADDR           = "http://${attr.unique.network.ip-address}:8500"
        NOMAD_SCRAPE_TOKEN    = var.nomad_scrape_token
        CONSUL_HTTP_TOKEN     = var.consul_token
        PROMETHEUS_ADMIN_HASH = var.prometheus_admin_hash
        PROMETHEUS_TECH_HASH  = var.prometheus_tech_hash
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }
  }
}
