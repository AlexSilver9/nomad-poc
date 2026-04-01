# Minimal read-only policy for Prometheus to scrape Nomad metrics.
# Used by setup_monitoring.sh to create a dedicated metrics-scraper token.

agent {
  policy = "read"
}

node {
  policy = "read"
}

namespace "default" {
  policy = "read"
}
