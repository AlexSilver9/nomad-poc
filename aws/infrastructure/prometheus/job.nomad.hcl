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

job "prometheus" {
  datacenters = ["dc1"]
  type        = "service"

  group "prometheus" {
    count = 1

    network {
      mode = "host"

      port "prometheus" {
        static = 9090
      }
    }

    volume "prometheus-data" {
      type      = "host"
      source    = "prometheus-data"
      read_only = false
    }

    task "prometheus" {
      driver = "docker"

      config {
        image        = "prom/prometheus:v3.2.1"
        network_mode = "host"

        args = [
          "--config.file=/local/prometheus.yml",
          "--storage.tsdb.path=/prometheus",
          "--web.listen-address=0.0.0.0:9090",
        ]
      }

      volume_mount {
        volume      = "prometheus-data"
        destination = "/prometheus"
        read_only   = false
      }

      # Generates prometheus.yml using Consul service discovery to find Nomad nodes.
      # Nomad agents register themselves in Consul as 'nomad' (servers) and 'nomad-client' (clients).
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
      - server: 'localhost:8500'
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
        replacement: '${1}:4646'
        target_label: __address__
      - source_labels: [__meta_consul_node]
        target_label: instance
      - source_labels: [__meta_consul_service]
        target_label: job
EOF
        destination = "local/prometheus.yml"
      }

      env {
        NOMAD_SCRAPE_TOKEN = var.nomad_scrape_token
        CONSUL_HTTP_TOKEN  = var.consul_token
      }

      resources {
        cpu    = 200
        memory = 256
      }

      service {
        name = "prometheus"
        port = "prometheus"

        check {
          type     = "http"
          path     = "/-/healthy"
          interval = "15s"
          timeout  = "3s"
        }
      }
    }
  }
}
