# Service resolver that excludes canary instances from receiving traffic
# This allows testing the canary in isolation before exposing it to users
#
# Apply: consul config write canary-update-service-resolver.hcl
# Delete (to enable canary traffic): consul config delete -kind service-resolver -name canary-update-service
#
# Note: Instead of a 'OnlyPassing' filter here, `Splits` are also possible.
# With Splits (service splitter combined with a service resolver that defines subsets) - the traffic
# can be shifted to canary instances gradually (e.g., 90/10 -> 50/50 -> 0/100).

Kind = "service-resolver"
Name = "canary-update-service"

# Only route to instances that do NOT have the "canary" tag
# Canary instances are tagged via canary_tags in the Nomad job
Filter = "\"canary\" not in Service.Tags"
