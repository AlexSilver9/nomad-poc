job "process-monitor" {
  datacenters = ["dc1"]
  type        = "system" # Run service on all nodes

  group "process-monitor" {
    task "print-processes" {
      driver = "docker"

      config {
        image   = "alpine:latest"
        command = "sh"
        args    = ["-c", "while true; do date; ps -f; sleep 30; done"]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }
  }
}