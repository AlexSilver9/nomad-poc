job "cron-job" {
  datacenters = ["dc1"]
  type        = "batch"

  # https://developer.hashicorp.com/nomad/docs/job-specification/periodic

  periodic {
    crons = [
        "5 * * * *",
    ]
    prohibit_overlap = true
    time_zone = "Europe/Berlin"
  }

  group "cron-job" {
    task "cron-task" {
      driver = "docker"
      config {
        image   = "alpine"
        command = "sh"
        args    = ["-c", "date && echo cron-job"]
      }
    }
  }
}