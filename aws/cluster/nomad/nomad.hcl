data_dir = "/opt/nomad/data"
bind_addr = "0.0.0.0"

plugin "docker" {
  config {
    allow_privileged = true
    volumes {
      enabled = true
    }
  }
}

server {
  enabled          = true
  bootstrap_expect = 3

  server_join {
    retry_join = [
      "172.17.45.133:4648",
      "172.17.34.232:4648",
      "172.17.34.232:4648"
    ]
  }
}

client {
  enabled = true

  servers = [
    "172.17.45.133:4647",
    "172.17.34.232:4647",
    "172.17.34.232:4647"
  ]

  # Classify node as server (e.g. to prevent running workloads)
  # options = {
  #   "node.class" = "server"
  # }
}