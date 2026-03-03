# ACL Policies

ACL policy definitions for Consul and Nomad. For the full setup and operational procedures see [ACL_IMPLEMENTATION.md](ACL_IMPLEMENTATION.md).

## Structure

```
aws/acl/
├── users.conf                        # User → role mapping (no secrets)
├── consul/
│   ├── policies/
│   │   ├── agent.policy.hcl          # Consul agent token policy
│   │   ├── nomad-server.policy.hcl   # Nomad's Consul integration token policy
│   │   ├── operator-readonly.policy.hcl
│   │   └── operator-readwrite.policy.hcl
│   └── roles/
│       ├── consul-readonly.role.hcl  # Role reference: consul-readonly
│       └── consul-readwrite.role.hcl        # Role reference: consul-readwrite
└── nomad/
    ├── policies/
    │   ├── deployer.policy.hcl       # Job deployment token policy
    │   ├── readonly.policy.hcl       # Read-only monitoring token policy
    │   └── node-operator.policy.hcl  # Node drain/enable token policy
    └── roles/
        ├── nomad-deployer.role.hcl   # Role reference: nomad-deployer
        ├── nomad-readonly.role.hcl   # Role reference: nomad-readonly
        └── nomad-node-operator.role.hcl
```

Policy and role reference files are committed to git. Token values are never committed — see `.gitignore` in this directory.

## Scripts

| Script | Where it runs | Purpose |
|---|---|---|
| [`aws/bin/cluster/bootstrap_acl.sh`](../aws/bin/cluster/bootstrap_acl.sh) | Local machine | One-time Day-2 ACL bootstrap for the whole cluster |
| [`aws/bin/instance/create_user_tokens.sh`](../aws/bin/instance/create_user_tokens.sh) | Cluster node | Create roles and personal user tokens (run after bootstrap) |
| [`aws/bin/cluster/enforce_acl.sh`](../aws/bin/cluster/enforce_acl.sh) | Local machine | Switch Consul from `allow` to `deny` (maintenance window) |
| [`aws/bin/instance/onboard_node.sh`](../aws/bin/instance/onboard_node.sh) | New instance | Apply ACL tokens when a new node joins |
