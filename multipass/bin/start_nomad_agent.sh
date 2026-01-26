#!/bin/sh

# Start Nomad agent manually using local config.
# Usage: ./start_nomad_agent.sh

./nomad agent -config=/etc/nomad.d/nomad.hcl