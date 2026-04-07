Kind = "service-intentions"
Name = "prometheus"

Sources = [
  {
    Name   = "api-gateway"
    Action = "allow"
  },
  {
    # Allow Grafana sidecar to reach Prometheus via the service mesh (east-west)
    Name   = "grafana"
    Action = "allow"
  }
]
