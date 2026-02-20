# ACL Policies

ACL policy definitions for Consul and Nomad. For the full setup and operational procedures see [ACL_IMPLEMENTATION.md](ACL_IMPLEMENTATION.md).

## Structure

```
aws/acl/
├── consul/policies/
│   ├── agent.policy.hcl          # Consul agent token policy
│   └── nomad-server.policy.hcl   # Nomad's Consul integration token policy
└── nomad/policies/
    ├── deployer.policy.hcl       # Job deployment token policy
    └── readonly.policy.hcl       # Read-only monitoring token policy
```

Policy files are committed to git and fetched from GitHub by the bootstrap and onboarding scripts. Token values are never committed — see `.gitignore` in this directory.

## Scripts

| Script | Where it runs | Purpose |
|---|---|---|
| [`aws/bin/cluster/bootstrap_acl.sh`](../aws/bin/cluster/bootstrap_acl.sh) | Local machine | One-time Day-2 ACL bootstrap for the whole cluster |
| [`aws/bin/cluster/enforce_acl.sh`](../aws/bin/cluster/enforce_acl.sh) | Local machine | Switch Consul from `allow` to `deny` (maintenance window) |
| [`aws/bin/instance/onboard_node.sh`](../aws/bin/instance/onboard_node.sh) | New instance | Apply ACL tokens when a new node joins |
