job "ipa-system-batch" {
  datacenters = ["dc1"]
  type        = "sysbatch" # Run batch on all nodes

  group "ipa-system-batch" {
    task "print-network-interfaces" {
      driver = "docker"

      config {
        image   = "alpine:latest"
        command = "sh"
        args    = ["-c", "ip a"]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }
  }
}