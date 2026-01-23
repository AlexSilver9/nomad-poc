# Introduction to Vault

https://www.youtube.com/watch?v=klyAhaklGNU

# Setup Vault

## Initialize Vault

```shell
export VAULT_ADDR=http://127.0.0.1:8200
vault operator init
```

Vault now prints 5 Unseal Keys and a Root Token like this:

```
Unseal Key 1: HIwWeOvaRXRDIYKAutXkyntpqUEQqClLlUUGwDre2t2G
Unseal Key 2: JKkqRiIHHRZbohfnKzhFyfMkX3EfiZdxFPEigrDKf+FL
Unseal Key 3: tkiS+M1PpSBmIJG/FCg3/euk+n6kWC5fYq9SWhtCTYvk
Unseal Key 4: FKcVGoX5EudNPr2qAbyhqX1Yr06EJe59orN+Bxse1AOj
Unseal Key 5: ryeT+pfkH0dInfurxee4Rcg91mX56LIFhr2W2IZl+PuE

Initial Root Token: hvs.LCEgYVz7j3Sdw2evNM49lfgd
```

Spread the 5 Unseal Keys to distinct locations.
Store the Root Token in an offline password manager or hardware vault.


Vault starts sealed and needs to be unsealed.

## Unseal Vault

https://developer.hashicorp.com/vault/docs/concepts/seal

Now at least 3 Unseal Keys are required to unseal Vault.
This can be done via CLI and/or UI.

On CLI  providing a key to each command:

```shell
vault operator unseal
vault operator unseal
vault operator unseal
```

UI is at: http://127.0.0.1:8200/

## First Login

Use Root Token to log in

```shell
vault login hvs.LCEgYVz7j3Sdw2evNM49lfgd
```

## Enable Audit Log

```shell
sudo mkdir -p /var/log
sudo touch /var/log/vault_audit.log
sudo chown vault:vault /var/log/vault_audit.log
sudo chmod 600 /var/log/vault_audit.log
vault audit enable file file_path=/var/log/vault_audit.log
```

## Enable KV Secrets Engine

```shell
vault secrets enable -path=secret kv-v2
vault kv put secret/hello value=world       # Create test secret 
vault kv get secret/hello                   # Read test secret
```

## Create non-root admin policy

Create `admin.hcl` policy file:

```hcl
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
```

Apply `admin.hcl` policy file:

```shell
vault policy write admin admin.hcl
```

Verify admin policy:

```shell
vault policy list
vault policy read admin
```

# Enable auth method AppRole (recommended for machines)

```shell
vault auth enable approle
```

Create role:

```shell
vault write auth/approle/role/admin \
  token_policies="admin" \
  token_ttl=1h \
  token_max_ttl=4h
```

Get admin role id:

```shell
vault read auth/approle/role/admin/role-id
```

Create secret id (-f = no body specified -> Vault will create data):

```shell
vault write -f auth/approle/role/admin/secret-id
```



# ------------------------------------------------------------------

# Concept

# Lease
Jedes Secret erzeugt un benötigt ein `Lease` (Metadata mit Infos zu Zeit, Dauer, Renew, ...).
Das `Lease` muss von Consumern innerhalb der TTL des Lease erneuert  (`Renew`) oder das Secret ersetzt (`Replace`) werden -> ´Key Rolling`.

# Revoke
Ein `Revoke` invalidiert ein Secret und verhindert weitere `Renew`s.

```shell
vault lease revoke
vault lease revoke -prefix mitel/ # Prefix basierter Revoke
# oder per UI
```

# Renew

```shell
vault lease renew
```

# Read Lease / Lease ID

```shell
vault read
```

# Authentication
Client -> Vault Auth -> Token & Policy 

Enable Auth Backend:

```shell
vault auth enable -path=my-auth userpass 
```
