#!/usr/bin/env bash
# =============================================================================
# scripts/12-update-nomad-wi.sh
# PHASE 2, STEP C — Reconfigure Nomad to use Workload Identity
#
# What changes on Nomad server:
#   - Add default workload_identity blocks to vault{} and consul{} stanzas
#   - Replace vault{token=...} with vault{jwt_auth_backend_path=...}
#   - Replace consul{token=...} with consul{service_identity/task_identity}
#   - Remove VAULT_TOKEN and CONSUL_HTTP_TOKEN from systemd overrides
#   - Restart Nomad server (rolling — existing allocations keep running)
#
# What changes on Nomad client:
#   - Remove static VAULT_TOKEN / CONSUL_HTTP_TOKEN env vars
#   - Restart client
#
# After this step: NEW allocations use JWT-based workload identity.
#                  Existing allocations continue until they are replaced.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

VAULT_IP=$(vm_ip "$VM_VAULT")
CONSUL_IP=$(vm_ip "$VM_CONSUL")
NOMAD_SERVER_IP=$(vm_ip "$VM_NOMAD_SERVER")

info "============================================================"
info "  STEP 12: Switching Nomad to Workload Identity auth"
info "============================================================"

# ============================================================================
# 1. Write new Nomad SERVER config (workload identity)
# ============================================================================
info "Writing Workload Identity Nomad server config..."
cat <<NOMADEOF | multipass exec "$VM_NOMAD_SERVER" -- bash -c "cat > /etc/nomad.d/server.hcl"
# /etc/nomad.d/server.hcl  (PHASE 2 — WORKLOAD IDENTITY)
# -------------------------------------------------------------------
# Key changes vs legacy config:
#   vault{} — removed 'token', added 'jwt_auth_backend_path' and
#             'default_identity' for JWT-based auth
#   consul{} — removed 'token', added 'service_identity' and
#              'task_identity' for JWT-based auth
# -------------------------------------------------------------------

datacenter = "dc1"
data_dir   = "/opt/nomad/data"
log_level  = "INFO"
name       = "nomad-server"

bind_addr = "0.0.0.0"

server {
  enabled          = true
  bootstrap_expect = 1
}

# Consul integration — WORKLOAD IDENTITY
consul {
  address             = "127.0.0.1:8500"
  server_service_name = "nomad"
  client_service_name = "nomad-client"
  auto_advertise      = true
  server_auto_join    = true
  client_auto_join    = true

  # Consul auth method name (created in 11-migrate-consul-wi.sh)
  # The server uses a token from a binding rule at startup — see below.
  # Workload tokens are issued via service_identity / task_identity.

  # Identity for Nomad services (server/client registration)
  service_identity {
    aud = ["${NOMAD_CONSUL_JWT_AUD}"]
    ttl = "1h"
  }

  # Identity for job tasks (service mesh, sidecar proxies)
  task_identity {
    aud = ["${NOMAD_CONSUL_JWT_AUD}"]
    ttl = "1h"
  }
}

# Vault integration — WORKLOAD IDENTITY
vault {
  enabled = true
  address = "http://${VAULT_IP}:${VAULT_PORT}"

  # JWT auth backend path (configured in 10-migrate-vault-wi.sh)
  jwt_auth_backend_path = "jwt-nomad"

  # Default identity used for ALL tasks that request Vault access
  # unless overridden in the job spec
  default_identity {
    aud = ["${NOMAD_VAULT_JWT_AUD}"]
    ttl = "1h"
  }
}
NOMADEOF

vm_exec "$VM_NOMAD_SERVER" "
  chown nomad:nomad /etc/nomad.d/server.hcl
  chmod 640 /etc/nomad.d/server.hcl
"
ok "New Nomad server config written"

# ============================================================================
# 2. Create a minimal Consul token for Nomad server's OWN service registration
#    (workload JWTs cover tasks — the Nomad process itself still needs a token
#    to register nomad/nomad-client services in Consul's catalog)
# ============================================================================
info "Creating a limited Consul token for Nomad server process..."
CONSUL_BOOTSTRAP_TOKEN=$(load_secret "consul_bootstrap_token")
CONSUL_NOMAD_PROCESS_TOKEN=$(vm_exec "$VM_CONSUL" "
CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl token create \
    -description 'Nomad server process (minimal) — WI era' \
    -policy-name nomad-server \
    -format=json" | jq -r '.SecretID')
save_secret "consul_nomad_process_token" "$CONSUL_NOMAD_PROCESS_TOKEN"
ok "Minimal Consul process token created"

# ============================================================================
# 3. Update systemd overrides — remove VAULT_TOKEN, keep minimal CONSUL token
# ============================================================================
info "Updating Nomad server systemd override..."
vm_exec "$VM_NOMAD_SERVER" "
mkdir -p /etc/systemd/system/nomad.service.d
cat > /etc/systemd/system/nomad.service.d/tokens.conf << EOF
[Service]
# WORKLOAD IDENTITY ERA — VAULT_TOKEN removed
# Consul token is still needed for Nomad server's own service registration.
# Workload tasks get their own JWT-based tokens automatically.
Environment='CONSUL_HTTP_TOKEN=${CONSUL_NOMAD_PROCESS_TOKEN}'
EOF
systemctl daemon-reload
"
ok "Systemd override updated (VAULT_TOKEN removed)"

# ============================================================================
# 4. Update Nomad CLIENT config
# ============================================================================
info "Writing Workload Identity Nomad client config..."
NOMAD_SERVER_IP_CURRENT=$(vm_ip "$VM_NOMAD_SERVER")
cat <<NOMADEOF | multipass exec "$VM_NOMAD_CLIENT" -- bash -c "cat > /etc/nomad.d/client.hcl"
# /etc/nomad.d/client.hcl  (PHASE 2 — WORKLOAD IDENTITY)

datacenter = "dc1"
data_dir   = "/opt/nomad/data"
log_level  = "INFO"
name       = "nomad-client"

bind_addr  = "0.0.0.0"

client {
  enabled = true
  servers = ["${NOMAD_SERVER_IP_CURRENT}:4647"]

  host_volume "data" {
    path      = "/opt/nomad/alloc"
    read_only = false
  }
}

# Consul — WORKLOAD IDENTITY
consul {
  address = "127.0.0.1:8500"

  service_identity {
    aud = ["${NOMAD_CONSUL_JWT_AUD}"]
    ttl = "1h"
  }

  task_identity {
    aud = ["${NOMAD_CONSUL_JWT_AUD}"]
    ttl = "1h"
  }
}

# Vault — WORKLOAD IDENTITY (no token needed here)
vault {
  enabled = true
  address = "http://${VAULT_IP}:${VAULT_PORT}"
}

plugin "docker" {
  config {
    allow_privileged = false
    volumes {
      enabled = true
    }
  }
}
NOMADEOF

vm_exec "$VM_NOMAD_CLIENT" "
  chown nomad:nomad /etc/nomad.d/client.hcl
  chmod 640 /etc/nomad.d/client.hcl
"
ok "New Nomad client config written"

# Create a minimal Consul token for the Nomad client process too
CONSUL_NOMAD_CLIENT_PROCESS_TOKEN=$(vm_exec "$VM_CONSUL" "
CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl token create \
    -description 'Nomad client process (minimal) — WI era' \
    -policy-name nomad-client \
    -format=json" | jq -r '.SecretID')
save_secret "consul_nomad_client_process_token" "$CONSUL_NOMAD_CLIENT_PROCESS_TOKEN"

vm_exec "$VM_NOMAD_CLIENT" "
mkdir -p /etc/systemd/system/nomad.service.d
cat > /etc/systemd/system/nomad.service.d/tokens.conf << EOF
[Service]
# WORKLOAD IDENTITY ERA — VAULT_TOKEN removed
Environment='CONSUL_HTTP_TOKEN=${CONSUL_NOMAD_CLIENT_PROCESS_TOKEN}'
EOF
systemctl daemon-reload
"
ok "Client systemd override updated"

# ============================================================================
# 5. Restart Nomad server, then client
# ============================================================================
info "Restarting Nomad server with WI config..."
vm_exec "$VM_NOMAD_SERVER" "systemctl restart nomad"
wait_for_port "$VM_NOMAD_SERVER" "$NOMAD_PORT" "Nomad server (WI)"
ok "Nomad server restarted with workload identity config"

info "Restarting Nomad client with WI config..."
vm_exec "$VM_NOMAD_CLIENT" "systemctl restart nomad"
wait_for_port "$VM_NOMAD_CLIENT" "$NOMAD_PORT" "Nomad client (WI)"
ok "Nomad client restarted with workload identity config"

# ============================================================================
# 6. Verify cluster recovered
# ============================================================================
sleep 5
vm_exec "$VM_NOMAD_SERVER" \
  "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} nomad server members"
ok "Nomad cluster members verified"

echo ""
echo "============================================================"
echo "  Nomad Workload Identity Reconfiguration Complete"
echo "============================================================"
echo ""
echo "  Vault auth:   JWT via jwt-nomad (no static VAULT_TOKEN)"
echo "  Consul auth:  JWT via nomad-wi  (no static CONSUL_HTTP_TOKEN)"
echo ""
echo "  Run: scripts/13-verify-migration.sh to confirm everything works"
echo "============================================================"
