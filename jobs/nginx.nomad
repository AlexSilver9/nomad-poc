job "nginx" {
  datacenters = ["dc1"]
  type        = "service"

  group "web" {
    count = 1

    task "nginx" {
      driver = "docker"

      config {
        image = "nginx:latest"
        ports = ["http"]
      }

      resources {
        cpu    = 500   # MHz
        memory = 256   # MB
      }
    }

    network {
      port "http" {
        static = 80
      }
    }
  }
}