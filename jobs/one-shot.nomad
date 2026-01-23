job "one-shot" {
  datacenters = ["dc1"]
  type        = "batch"

  group "one-shot" {
    task "print-something" {
      driver = "docker"

      config {
        image   = "alpine:latest"
        command = "sh"
        args    = ["-c", "echo Hallo One-Shot Batch Job"]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }
  }
}