# Nomad → Workload Identity Migration Lab

> ! This is a lab environment for demonstration purposes only. Do not use this setup in production. It is very simplified and omits critical security and HA considerations. 

Migrates a Nomad cluster from **legacy static token auth** (Vault + Consul) to
**Workload Identity (JWT-based)** auth. All services run in Multipass VMs on your local machine.

Supported host platforms: **macOS**, **Linux**, **Windows (WSL2)**.


## Versions

| Service | Default Version |
|---------|---------|
| Vault   | 1.16.x  |
| Consul  | 1.21.x  |
| Nomad   | 1.8.x   |

> Edit `env.sh` to pin exact patch versions before running.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  macOS host (Multipass)                             │
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
| `nomad-client` | Nomad client (task runner) |

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
  - Claims mapped: `nomad_job_id`, `nomad_namespace`, `nomad_task`
  - Token policy: `nomad-workloads-wi`
- Creates policy `nomad-workloads-wi` (same paths as legacy, different grant mechanism)

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
- Creates JWT auth method `nomad-wi`:
  - JWKS URL: Nomad server
  - Bound audiences: `["consul.io"]`
  - Claim mappings for `nomad_job_id`, `nomad_namespace`, `nomad_task`
- Creates binding rule: any JWT with `nomad_job_id != ""` → `nomad-workloads` role

---

#### Step 12 — Switch Nomad to Workload Identity

```bash
make migrate-nomad
# or: scripts/12-update-nomad-wi.sh
```

This is the moment of migration. Changes:

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
  Same JWT (audience "consul.io") presented to Consul nomad-wi auth method
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
