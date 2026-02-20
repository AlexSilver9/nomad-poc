# ACL

Consul and Nomad ACL is a Day-2 operation — the cluster runs without ACL first, then ACL is enabled on the running cluster once it is validated. This document describes the setup and operational procedures.

## Overview

Both Consul and Nomad have independent ACL systems. Consul must be bootstrapped first because Nomad needs a Consul token to use the service mesh once Consul has ACL enabled.

ACL is enabled in two phases to avoid service disruption:

1. **Transition phase** — ACL is enabled with `default_policy = "allow"`. Existing traffic is unaffected. Tokens are created and distributed.
2. **Enforcement phase** — `default_policy` is switched to `"deny"` in a maintenance window. Unauthenticated access to both UIs and APIs is blocked.

## File Layout

```
aws/acl/
├── .gitignore                        # Blocks token files from git
├── consul/policies/
│   ├── agent.policy.hcl              # Consul agent token policy
│   └── nomad-server.policy.hcl       # Nomad's Consul integration token policy
└── nomad/policies/
    ├── deployer.policy.hcl           # Job deployment token policy
    └── readonly.policy.hcl           # Read-only monitoring token policy
```

Policy HCL files are committed to git and fetched from GitHub by the bootstrap script. Token values are never committed.

## Tokens

### Consul

| Token | Consumer | Policy |
|---|---|---|
| Management | Product owner → password manager | Built-in (full access) |
| Agent | Every Consul agent | `agent.policy.hcl` |
| Nomad server | Nomad's `consul {}` block | `nomad-server.policy.hcl` |

A single shared agent token is used across all nodes. It is applied at runtime via `consul acl set-agent-token agent <token>` and persisted to disk by `enable_token_persistence = true`, so it survives restarts without re-application.

The Nomad server token is written to `/etc/nomad.d/consul-token.hcl` on each node as a separate config file (not part of the main `nomad.hcl`). Nomad merges all `.hcl` files in `/etc/nomad.d/` at startup.

### Nomad

| Token | Consumer | Policy |
|---|---|---|
| Management | Product owner → password manager | Built-in (full access) |
| Deployer | CI/CD systems, engineers | `deployer.policy.hcl` |
| Read-only | Monitoring systems | `readonly.policy.hcl` |

## ACL Config Files

The bootstrap script writes separate ACL config files rather than modifying the main `consul.hcl` / `nomad.hcl`:

- `/etc/consul.d/acl.hcl` — Consul ACL block
- `/etc/nomad.d/acl.hcl` — Nomad ACL block

Both config directories auto-load all `.hcl` files from the top-level directory only (subdirectories are not traversed), so these files are picked up automatically on restart.

## Bootstrapping an Existing Cluster

Run once from the local machine after the cluster is healthy:

```sh
./aws/bin/cluster/bootstrap_acl.sh
```

The script connects to all nodes via SSH and runs four phases:

**Phase 0** — Writes `/etc/consul.d/acl.hcl` and `/etc/nomad.d/acl.hcl` to every node. Performs a rolling restart of Consul (one node at a time), waits for the cluster to stabilise, then writes the Nomad ACL config.

**Phase 1** — Bootstraps Consul ACL on one server node. Fetches policy files from GitHub via `wget` and applies them. Creates the agent token and Nomad server token. Applies the agent token to every node via `consul acl set-agent-token`.

**Phase 2** — Writes the Nomad server Consul token to `/etc/nomad.d/consul-token.hcl` on every node. Performs a rolling restart of Nomad and waits for the cluster to stabilise.

**Phase 3** — Bootstraps Nomad ACL on one server node. Fetches and applies Nomad policy files from GitHub. Creates the deployer and read-only tokens.

All tokens are written to `aws/acl/bootstrap-output.txt` (gitignored). This file should be read once, tokens transferred to the password manager, then deleted.

If the script is run again after a successful bootstrap, the bootstrap steps are skipped (both `consul acl bootstrap` and `nomad acl bootstrap` detect the already-bootstrapped state and exit gracefully).

## Adding a New Node

After running the standard setup scripts on the new instance, run:

```sh
./aws/bin/instance/onboard_node.sh
```

The script prompts for the Consul agent token and the Nomad Consul token (both from the password manager). If the cluster is already in enforce mode (`default_policy = "deny"`), it also prompts for the Consul management token, which is required to authenticate the agent token application. It then:

1. Writes `/etc/consul.d/acl.hcl` and restarts Consul
2. Applies the agent token via `consul acl set-agent-token`
3. Writes `/etc/nomad.d/acl.hcl` and `/etc/nomad.d/consul-token.hcl`
4. Restarts Nomad

## Switching to Enforce Mode

Once all token consumers are configured, run from the local machine:

```sh
./aws/bin/cluster/enforce_acl.sh
```

The script prompts for confirmation, then updates `default_policy` from `"allow"` to `"deny"` in `/etc/consul.d/acl.hcl` on each node and does a rolling restart of Consul. Nomad ACL denies unauthenticated access by default — no change needed there.

---

## Recovery Procedures

### Nomad: Recovering a Lost Management Token

Nomad supports resetting the bootstrap state via a file placed on the **Raft leader before restart**. Existing policies and non-management tokens survive.

**Step 1 — Get the reset index.**
Run `nomad acl bootstrap` on any node. Even though it fails, the error includes the reset index:
```
Error bootstrapping: Unexpected response code: 400 (ACL bootstrap already done (reset index: 138))
```

**Step 2 — Identify the Raft leader.**
On each server node, check the Nomad logs:
```sh
journalctl -u nomad | grep "cluster leadership acquired"
```
Only the current leader will show this. If you cannot determine the leader, write the file to all three nodes — the leader will process it.

**Step 3 — Write the reset file on the leader.**
```sh
echo "138" | sudo tee /opt/nomad/data/server/acl-bootstrap-reset
```

**Step 4 — Restart Nomad on that node.**
```sh
sudo systemctl restart nomad
```
Nomad reads the file at startup, resets the bootstrap state, and deletes the file.

**Step 5 — Re-bootstrap to get a new management token.**
```sh
nomad acl bootstrap
```
This succeeds and prints the new management token. Save it immediately.

---

### Consul: Recovering a Lost Management Token

Consul has no reset-file mechanism equivalent to Nomad's. **Prevention is the right answer.**

#### Prevention: `initial_management` token

Before running `consul acl bootstrap` for the first time, add a pre-chosen UUID to `consul.hcl`:

```hcl
acl {
  enabled = true
  tokens {
    initial_management = "00000000-0000-0000-0000-000000000001"
  }
}
```

When `consul acl bootstrap` runs, this becomes the management token. Since you chose the value, it can never be lost — store it in the password manager the same as any other credential. This project does not currently use this approach (we rely on saving the bootstrap output), but it is preferable for production.

**Important**: `initial_management` is read exactly once — at bootstrap time. After that, the token lives in Raft and the config value has no effect. Changing or removing it from `consul.hcl` after bootstrapping does nothing to the active token. You can safely remove it from the config after bootstrapping to eliminate the static secret from disk.

#### Recovery: Wipe Raft state (destructive)

If the management token is truly lost and no `initial_management` token was configured, the only recovery is to wipe the Raft/FSM state on all server nodes. This destroys **all** ACL data (tokens, policies, service registrations stored in Raft) and requires re-running the full bootstrap procedure:

```sh
# On each server node — stop Consul first
sudo systemctl stop consul
sudo rm -rf /opt/consul/data/raft /opt/consul/data/serf
sudo systemctl start consul
# Wait for the cluster to reform, then:
consul acl bootstrap
```

This is equivalent to starting from scratch. Do not do this in production without a maintenance window and full understanding of what will be lost.
