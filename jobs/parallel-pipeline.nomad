job "parallel-pipeline" {
  datacenters = ["dc1"]
  type        = "batch"

  group "pipeline" {
    task "step1" {
      driver = "docker"
      config {
        image   = "alpine:latest"
        command = "sh"
        args    = ["-c", "date; echo step 1; sleep 5; date"]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    task "step2" {
      driver = "docker"
      config {
        image   = "alpine:latest"
        command = "sh"
        args    = ["-c", "date; echo step 2; sleep 5; date"]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    task "step3" {
      driver = "docker"
      config {
        image   = "alpine:latest"
        command = "sh"
        args    = ["-c", "date; echo step 3; sleep 5; date"]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }
  }
}