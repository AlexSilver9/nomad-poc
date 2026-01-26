job "sequential-pipeline" {
  datacenters = ["dc1"]
  type        = "batch"

  group "pipeline" {

    # https://developer.hashicorp.com/nomad/docs/job-specification/lifecycle

    # e.g. for Init tasks or waiting for something
    task "prestart" {
      lifecycle {
        hook = "prestart"
      }

      driver = "docker"
      config {
        image   = "alpine"
        command = "sh"
        args    = ["-c", "date; echo step prestart; sleep 5; date"]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    # e.g. for one-shot / ephemeral sidecar
    task "poststart" {
      lifecycle {
        hook = "poststart"
        sidecar = "true" # optional definition
      }

      driver = "docker"
      config {
        image   = "alpine"
        command = "sh"
        args    = ["-c", "date; echo step poststart; sleep 5; date"]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    # e.g. for long lived sidecar (log shipper, proxies, jvm debug/profiler agent)
    task "sidecar" {
      lifecycle {
        hook = "poststart"
        sidecar = "true"
      }

      driver = "docker"
      config {
        image   = "alpine"
        command = "sh"
        args    = ["-c", "date; echo step sidecar; sleep 5; date"]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    # the main task to be performed
    task "main-task" {
      driver = "docker"
      config {
        image   = "alpine"
        command = "sh"
        args    = ["-c", "date; echo step main-task; sleep 5; date"]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    # e.g. for cleanup actions
    task "poststop" {
      lifecycle {
        hook = "poststop"
      }

      driver = "docker"
      config {
        image   = "alpine"
        command = "sh"
        args    = ["-c", "date; echo step poststop; sleep 5; date"]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }
  }
}