job "whoami" {
  datacenters = ["dc1"]
  type        = "service"

  group "whoami" {
    count = 3   # 1 Allocation / Node

    task "whoami" {
      driver = "docker"

      config {
        image = "traefik/whoami:latest"
        ports = ["http"]
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }

    network {
      port "http" {
        to = 80 # Nomad maps container port 80 to some dynamic host port
      }
    }

    constraint {
      operator = "distinct_hosts" # Force each alloc to dedicated host
    }
  }
}