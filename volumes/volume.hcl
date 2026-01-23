id        = "test-volume-1"
name      = "test-volume-1"
type      = "csi"
plugin_id = "hostpath"

capacity_min = "1GiB"
capacity_max = "2GiB"

# Im Job:
#
# group "app" {
#   volume "data" {
#     type      = "csi"
#     source    = "test-volume-1"
#     read_only = false
#   }
# 
#   task "app" {
#     driver = "docker"
# 
#     volume_mount {
#       volume      = "data"
#       destination = "/data"
#     }
#   }
# }