# Nomad → Workload Identity Migration Lab

> [!WARNING]
> This is a lab environment for demonstration purposes only. Do not use this setup in production. It is very simplified and omits critical security and HA considerations. 

Migrates a Nomad cluster from **legacy static token auth** (Vault + Consul) to
**Workload Identity (JWT-based)** auth. All services run in Multipass VMs on your local machine.

Supported host platforms: **macOS**, **Linux**, **Windows (WSL2)**.


## Versions

Workload Identity was introduced in Nomad 1.7, but Nomad 1.8 was the first LTS release.

> Edit `env.sh` to pin exact patch versions before running.

| Service | Default Version |
|---------|---------|
| Vault   | 1.16.x  |
| Consul  | 1.21.x  |
| Nomad   | 1.8.x   |



## Architecture

```
┌─────────────────────────────────────────────────────┐
│  host machine (Multipass)                           │
│                                                     │
│  ┌──────────────┐    ┌──────────────────────────┐   │
│  │ vault-server │    │     consul-server        │   │
│  │  :8200       │    │  :8500 (ACLs enabled)    │   │
│  └──────┬───────┘    └─────────────┬────────────┘   │
│         │ JWT auth                 │ JWT auth       │
│  ┌──────┴──────────────────────────┴────────────┐   │
│  │              nomad-server  :4646             │   │
│  │  Exposes /.well-known/jwks.json (OIDC)       │   │
│  └──────────────────────┬───────────────────────┘   │
│                         │ allocations               │
│  ┌──────────────────────┴───────────────────────┐   │
│  │              nomad-client  :4646             │   │
│  │  Runs tasks + injects WI JWTs                │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

---

## Quick Start

```bash
# Prerequisites
source env.sh

# Phase 1 — Full legacy deployment
make deploy

# Verify legacy works
make verify-legacy

# Phase 2 — Migrate to workload identity
make migrate
```

---

## Step-by-Step

### Prerequisites

#### macOS

```bash
brew install multipass make jq
```

#### Linux (Ubuntu/Debian)

```bash
sudo snap install multipass
sudo apt-get install -y make jq
```

#### Windows (WSL2)

WSL2 is required — the scripts use bash and standard POSIX tools that are not available in cmd/PowerShell.

**1. Install WSL2 with Ubuntu 22.04** (run in PowerShell as Administrator):

```powershell
wsl --install -d Ubuntu-22.04
```

Restart when prompted, then open the Ubuntu terminal and complete the user setup.

**2. Install Multipass on the Windows host** (not inside WSL2):

Download and run the installer from [multipass.run](https://multipass.run/install). Multipass runs as a Windows service and is called from WSL2 over the Windows path.

**3. Expose the Multipass CLI to WSL2**:

Add the Windows Multipass binary to your WSL2 PATH. In your `~/.bashrc` or `~/.zshrc` inside WSL2:

```bash
export PATH="$PATH:/mnt/c/Program Files/Multipass/bin"
```

Reload your shell and verify:

```bash
source ~/.bashrc
multipass version
```

**4. Install dependencies inside WSL2**:

```bash
sudo apt-get update
sudo apt-get install -y make jq
```

**5. `make ui` on WSL2**:

The `make ui` target uses `open` (macOS-only). On WSL2, use `wslview` instead:

```bash
# Install wslu for wslview
sudo apt-get install -y wslu

# Then open UIs manually
source env.sh
wslview "http://$(multipass info vault-server | awk '/IPv4/{print $2}'):8200"
wslview "http://$(multipass info consul-server | awk '/IPv4/{print $2}'):8500"
wslview "http://$(multipass info nomad-server | awk '/IPv4/{print $2}'):4646"
```

**Known WSL2 quirks**:

- Multipass VMs get IPs on the Windows Hyper-V network. They are reachable from WSL2 but you may need to add a route: `sudo ip route add <vm-subnet> via <hyperv-gateway>`
- If `multipass list` hangs, ensure the Multipass service is running in Windows: `Get-Service Multipass` in PowerShell
- File paths passed to `multipass transfer` must use Linux paths (e.g. `/home/user/...`), not Windows paths

---

#### Verify setup (all platforms)

```bash
# Verify Multipass is installed
multipass version

# Clone and enter the repo
cd nomad-consul-vault-workload-identity-migration

# Review and adjust versions
vi env.sh
```

---

### Phase 1 — Legacy Deployment

#### Step 0 — Create VMs

```bash
make vms
# or: scripts/00-create-vms.sh
```

Creates 4 Multipass VMs using Ubuntu 22.04 and `cloud-init/base.yaml`.

| VM | Role |
|----|------|
| `vault-server` | Vault storage backend |
| `consul-server` | Consul server with ACLs |
| `nomad-server` | Nomad server (scheduler) |
| `nomad-client` | Nomad client (runs workloads) |

---

#### Step 1 — Install Vault

```bash
make vault
# or: scripts/01-install-vault.sh
```

- Installs Vault via HashiCorp apt repo
- Writes `/etc/vault.d/vault.hcl` (Raft storage, TLS disabled for lab)
- Starts `vault.service`

---

#### Step 2 — Install Consul

```bash
make consul
# or: scripts/02-install-consul.sh
```

- Installs Consul with ACLs enabled (`default_policy = "deny"`)
- Generates and saves gossip encryption key
- Starts `consul.service`

---

#### Step 3 — Install Nomad Server (Legacy Config)

```bash
make nomad-server
# or: scripts/03-install-nomad-server.sh
```

- Installs Nomad + Consul agent (client mode)
- Writes **legacy** `/etc/nomad.d/server.hcl`:
  - `vault { enabled = true; address = "..." }` — token injected later
  - `consul { address = "..." }` — token injected later

---

#### Step 4 — Install Nomad Client (Legacy Config)

```bash
make nomad-client
# or: scripts/04-install-nomad-client.sh
```

- Installs Nomad + Consul agent (client mode) + Docker
- Writes **legacy** `/etc/nomad.d/client.hcl`

---

#### Step 5 — Bootstrap (Vault + Consul + Nomad)

```bash
make bootstrap
# or: scripts/05-bootstrap.sh
```

This is the largest step. It:

1. **Vault init + unseal** — saves unseal key + root token to `.secrets/`
2. **Consul ACL bootstrap** — creates server and client tokens for Nomad
3. **Vault setup**:
   - Enables KV-v2 at `secret/`
   - Creates `nomad-workloads-legacy` policy
   - Creates `nomad-cluster` token role
   - Creates a long-lived Vault token for the Nomad server
4. **Injects tokens** into Nomad systemd overrides:
   - `VAULT_TOKEN` → Nomad server and client
   - `CONSUL_HTTP_TOKEN` → Nomad server and client
5. Starts Nomad server + client

**Legacy token flow:**

```
Nomad server ──VAULT_TOKEN──► Vault  (creates child tokens for tasks)
                                       └── task gets VAULT_TOKEN env var

Nomad server ──CONSUL_TOKEN──► Consul (shared by all tasks via Nomad)
```

---

#### Step 6 — Verify Legacy

```bash
make verify-legacy
# or: scripts/06-verify-legacy.sh
```

- Checks Vault, Consul, and Nomad health
- Deploys `jobs/demo-legacy.nomad`
- Confirms the task reads `secret/demo/config` via legacy Vault token

---

### Phase 2 — Workload Identity Migration

**The migration order matters:**

```
Vault   ← configure JWT auth FIRST  (no Nomad downtime)
Consul  ← configure JWT auth SECOND (no Nomad downtime)
Nomad   ← switch config LAST        (brief restart, zero job downtime)
```

---

#### Step 10 — Configure Vault JWT Auth

```bash
make migrate-vault
# or: scripts/10-migrate-vault-wi.sh
```

Changes on Vault (Nomad is **unchanged** at this step):

- Enables `jwt` auth method at path `jwt-nomad`
- Configures JWKS URL: `http://<nomad-server>:4646/.well-known/jwks.json`
- Creates JWT role `nomad-workloads`:
  - `bound_audiences = ["vault.io"]`
  - `user_claim = "nomad_job_id"` (bare name — no leading `/`)
  - Claims mapped: `nomad_job_id`, `nomad_namespace`, `nomad_task`, `nomad_allocation_id`
  - Token policy: `nomad-workloads-wi`
  - `token_period = "30m"` — Nomad renews the token before it expires
- Creates policy `nomad-workloads-wi` (same paths as legacy, different grant mechanism):
  - `secret/data/demo/*` — read
  - `auth/token/lookup-self` — read
  - `auth/token/renew-self` — update (required so Nomad can renew short-lived task tokens)

**At this point:** Vault is ready to accept Nomad JWTs, but Nomad hasn't switched yet. Legacy tokens still work.

---

#### Step 11 — Configure Consul JWT Auth

```bash
make migrate-consul
# or: scripts/11-migrate-consul-wi.sh
```

Changes on Consul (Nomad is **unchanged** at this step):

- Creates policy `nomad-workloads-wi` (service/node read, service write)
- Creates role `nomad-workloads` bound to that policy
- Creates JWT auth method **`nomad-workloads`** (Nomad's default expected name):
  - JWKS URL: Nomad server `/.well-known/jwks.json`
  - Bound audiences: `["consul.io"]`
  - Claim mappings for `nomad_job_id`, `nomad_namespace`, `nomad_task`, `nomad_allocation_id`
  - Only `RS256` is listed — `EdDSA` is not supported in Consul ≤ 1.16
- Creates binding rule: any JWT with `nomad_job_id != ""` → `nomad-workloads` role

> **Why `nomad-workloads`?** Nomad 1.7+ looks for this exact auth method name by default when deriving per-task Consul tokens. Using any other name requires additional Nomad server config.

---

#### Step 12 — Switch Nomad to Workload Identity

```bash
make migrate-nomad
# or: scripts/12-update-nomad-wi.sh
```

This is the moment of migration. It performs the following in order:

1. Writes the new **Nomad server config** with JWT-based Vault + Consul stanzas (via `multipass transfer` — writes locally, transfers to VM, then `sudo mv` into place)
2. Creates a **minimal Consul token** for the Nomad server process itself (Nomad still needs a token for its own service registration in Consul — workload JWTs only cover task traffic)
3. **Renames the Consul auth method** to `nomad-workloads` if an old `nomad-wi` method exists from a previous run
4. **Enables Consul ACLs** on the Consul client agents running on both Nomad VMs (`/etc/consul.d/acl.hcl`) — without this, the local agent returns `ACL support disabled` and JWT login fails
5. Updates the **Nomad server systemd override** — removes `VAULT_TOKEN`, keeps a minimal `CONSUL_HTTP_TOKEN`
6. Writes the new **Nomad client config** with JWT-based Consul stanzas
7. Creates a **minimal Consul token** for the Nomad client process
8. Updates the **Nomad client systemd override** similarly
9. Restarts Nomad server, then client

Changes to configs:

**Nomad server config** (`/etc/nomad.d/server.hcl`):

```hcl
# BEFORE (legacy)
vault {
  enabled = true
  address = "http://vault:8200"
  # token injected via VAULT_TOKEN env var
}
consul {
  address = "127.0.0.1:8500"
  # token injected via CONSUL_HTTP_TOKEN env var
}

# AFTER (workload identity)
vault {
  enabled               = true
  address               = "http://vault:8200"
  jwt_auth_backend_path = "jwt-nomad"   # ← new
  default_identity {                    # ← new
    aud = ["vault.io"]
    ttl = "1h"
  }
}
consul {
  address = "127.0.0.1:8500"
  service_identity {                    # ← new
    aud = ["consul.io"]
    ttl = "1h"
  }
  task_identity {                       # ← new
    aud = ["consul.io"]
    ttl = "1h"
  }
}
```

**Systemd overrides**:

```bash
# BEFORE
Environment='VAULT_TOKEN=hvs.CAESIHe...'       # removed
Environment='CONSUL_HTTP_TOKEN=d4e9...'        # kept (minimal, process-only)

# AFTER
Environment='CONSUL_HTTP_TOKEN=<minimal-token>'  # only for Nomad's own service registration
```

Both Nomad server and client are restarted. Running jobs continue on the client during the restart.

---

#### Step 13 — Verify Migration

```bash
make verify-wi
# or: scripts/13-verify-migration.sh
```

- Confirms `VAULT_TOKEN` is gone from Nomad systemd overrides
- Verifies Vault can fetch the Nomad JWKS
- Deploys `jobs/demo-wi.nomad`
- Confirms the task reads Vault secrets via JWT (no static token)
- Checks for remaining legacy lease count

---

### Workload Identity Token Flow (After Migration)

```
Nomad server generates JWT for each allocation:
  {
    "aud": ["vault.io"],
    "sub": "global:default:demo-wi:reader:reader",
    "nomad_job_id": "demo-wi",
    "nomad_namespace": "default",
    "nomad_task": "reader",
    "nomad_allocation_id": "abc-123"
  }

Task runtime:
  NOMAD_SECRETS_DIR/vault_default.jwt  ← JWT written here by Nomad client

Template engine (inside Nomad):
  Reads JWT → presents to Vault jwt-nomad auth method
  Vault validates JWT signature via JWKS → issues short-lived Vault token
  Template engine uses that token to read secrets
  Token revoked when allocation ends

Consul:
  Same JWT (audience "consul.io") presented to Consul nomad-workloads auth method
  Consul issues an ACL token per task → service registered under that token
```

---

## Useful Commands

```bash
# VM status and IPs
make status

# Open all UIs in browser
make ui

# View secrets
make secrets

# Shell into a VM
make shell VM=vault-server

# Stop/start VMs
make stop
make start

# Unseal Vault after VM restart
make unseal

# Destroy everything
make clean
```

## Troubleshooting

**Vault sealed after restart:**
```bash
make unseal
```

**Nomad client not joining:**
```bash
make shell VM=nomad-server
NOMAD_ADDR=http://127.0.0.1:4646 nomad node status
```

**JWT auth failing:**
```bash
# Check JWKS endpoint is reachable from Vault VM
make shell VM=vault-server
curl http://<nomad-server-ip>:4646/.well-known/jwks.json | jq .

# Check Vault JWT config
VAULT_ADDR=http://127.0.0.1:8200 vault read auth/jwt-nomad/config
```

**Task can't read Vault secret:**
```bash
# Check the allocation logs
make shell VM=nomad-server
NOMAD_ADDR=http://127.0.0.1:4646 nomad job status demo-wi
NOMAD_ADDR=http://127.0.0.1:4646 nomad alloc logs <alloc-id> reader
```

**Task stuck at "Building Task Directory" / template hanging:**
```bash
# Check Nomad client service logs — the real error is here, not in the UI
make shell VM=nomad-client
sudo journalctl -u nomad --since "5 minutes ago" | tail -40
```
Common causes:
- Vault JWT role has wrong `user_claim` (must be `nomad_job_id`, not `/nomad_job_id`)
- Vault policy missing `auth/token/renew-self` — task token can't renew itself
- `\$VAR` in job template renders as a literal `\$` — use `$VAR` directly (Nomad's template engine only processes `{{ }}`)

**Consul pre-run hook fails: `ACL support disabled`:**

The Consul client agent on the Nomad VM doesn't have ACLs enabled. Script 12 adds `/etc/consul.d/acl.hcl` to fix this, but if you're setting up manually:
```bash
# On nomad-server and nomad-client VMs:
sudo tee /etc/consul.d/acl.hcl > /dev/null <<EOF
acl {
  enabled        = true
  default_policy = "deny"
  tokens {
    agent = "<bootstrap-token>"
  }
}
EOF
sudo systemctl restart consul
```

**Consul pre-run hook fails: `auth method "nomad-workloads" not found`:**

Nomad 1.7+ looks for a Consul auth method named exactly `nomad-workloads`. If the method was created under a different name, delete it and recreate:
```bash
consul acl auth-method delete -name <old-name>
# Then re-run scripts/11-migrate-consul-wi.sh
```

**`consul acl role update` fails: `Cannot update a role without specifying the -id parameter`:**

Consul requires `-id` (not `-name`) for role updates. Read the ID first:
```bash
ROLE_ID=$(consul acl role read -name nomad-workloads -format json | jq -r '.ID')
consul acl role update -id "$ROLE_ID" -policy-name nomad-workloads-wi
```

## Post-Migration Cleanup

Once all jobs are confirmed working on workload identity:

1. Revoke the legacy Vault Nomad server token:
   ```bash
   vault token revoke -accessor <accessor>
   ```
2. Delete the legacy Vault token role `nomad-cluster`
3. Delete the legacy Vault policy `nomad-workloads-legacy`
4. Revoke the legacy Consul Nomad tokens (server + client)
5. Remove `.secrets/vault_nomad_server_token` and `consul_nomad_*_token` files

## Security Notes

- `.secrets/` contains plaintext tokens — **never commit this directory**
- TLS is disabled for this lab — enable it in production
- The Vault root token is saved for lab convenience — revoke it post-setup in production
- Single-node Raft (Vault) and single-server Consul/Nomad are not HA — scale out for production
