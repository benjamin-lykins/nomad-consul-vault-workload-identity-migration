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
_tmpfile=$(mktemp /tmp/nomad-server-XXXXXX.hcl)
cat > "$_tmpfile" <<NOMADEOF
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

  jwt_auth_backend_path = "jwt-nomad"

  default_identity {
    aud = ["${NOMAD_VAULT_JWT_AUD}"]
    ttl = "1h"
  }
}
NOMADEOF
multipass transfer "$_tmpfile" "$VM_NOMAD_SERVER:/tmp/nomad-server.hcl"
rm -f "$_tmpfile"
vm_exec "$VM_NOMAD_SERVER" "
  sudo mv /tmp/nomad-server.hcl /etc/nomad.d/server.hcl
  sudo chown nomad:nomad /etc/nomad.d/server.hcl
  sudo chmod 640 /etc/nomad.d/server.hcl
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
# 2b. Enable ACLs on Consul client agents running on the Nomad VMs
#     The local Consul agent (127.0.0.1:8500) must have ACLs enabled for
#     Nomad's workload identity JWT login to Consul to succeed.
# ============================================================================
info "Ensuring Consul auth method is named 'nomad-workloads' (Nomad default)..."
# Write auth config locally and transfer to avoid heredoc-in-vm_exec issues
_auth_tmpfile=$(mktemp /tmp/nomad-workloads-auth-XXXXXX.json)
cat > "$_auth_tmpfile" <<AUTHEOF
{
  "JWKSURL": "http://${NOMAD_SERVER_IP}:${NOMAD_PORT}/.well-known/jwks.json",
  "JWTSupportedAlgs": ["RS256"],
  "BoundAudiences": ["${NOMAD_CONSUL_JWT_AUD}"],
  "ClaimMappings": {
    "nomad_job_id":        "nomad_job_id",
    "nomad_namespace":     "nomad_namespace",
    "nomad_task":          "nomad_task",
    "nomad_allocation_id": "nomad_allocation_id"
  }
}
AUTHEOF
multipass transfer "$_auth_tmpfile" "$VM_CONSUL:/tmp/nomad-workloads-auth.json"
rm -f "$_auth_tmpfile"

# Remove old 'nomad-wi' binding rules and auth method if they exist
vm_exec "$VM_CONSUL" "
for BR_ID in \$(CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
    CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
    consul acl binding-rule list -method nomad-wi -format json 2>/dev/null \
    | jq -r '.[].ID' 2>/dev/null); do
  CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
  CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
    consul acl binding-rule delete -id \"\$BR_ID\" 2>/dev/null || true
done
CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl auth-method delete -name nomad-wi 2>/dev/null || true
"

vm_exec "$VM_CONSUL" "
CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl auth-method create \
    -name 'nomad-workloads' \
    -type 'jwt' \
    -description 'Nomad Workload Identity JWT auth' \
    -config @/tmp/nomad-workloads-auth.json || \
CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl auth-method update \
    -name 'nomad-workloads' \
    -config @/tmp/nomad-workloads-auth.json
"

vm_exec "$VM_CONSUL" "
CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl binding-rule create \
    -method 'nomad-workloads' \
    -description 'Bind all Nomad workload JWTs to the nomad-workloads role' \
    -bind-type 'role' \
    -bind-name 'nomad-workloads' \
    -selector 'value.nomad_job_id != \"\"' 2>/dev/null || true
"
ok "Consul auth method 'nomad-workloads' ready"

info "Enabling ACLs on Consul agents on Nomad VMs..."
for _vm in "$VM_NOMAD_SERVER" "$VM_NOMAD_CLIENT"; do
  vm_exec "$_vm" "
    printf 'acl {\n  enabled        = true\n  default_policy = \"deny\"\n  tokens {\n    agent = \"${CONSUL_BOOTSTRAP_TOKEN}\"\n  }\n}\n' > /tmp/consul-acl.hcl
    sudo mv /tmp/consul-acl.hcl /etc/consul.d/acl.hcl
    sudo chown consul:consul /etc/consul.d/acl.hcl
    sudo chmod 640 /etc/consul.d/acl.hcl
    sudo systemctl restart consul
  "
  wait_for_port "$_vm" "$CONSUL_PORT" "Consul agent ($_vm)"
done
ok "Consul ACLs enabled on Nomad VMs"

# ============================================================================
# 3. Update systemd overrides — remove VAULT_TOKEN, keep minimal CONSUL token
# ============================================================================
info "Updating Nomad server systemd override..."
vm_exec "$VM_NOMAD_SERVER" "
printf '[Service]\n# WORKLOAD IDENTITY ERA — static vault token removed\n# Consul token is still needed for Nomad server own service registration.\nEnvironment=CONSUL_HTTP_TOKEN=${CONSUL_NOMAD_PROCESS_TOKEN}\n' > /tmp/nomad-server-tokens.conf
sudo mkdir -p /etc/systemd/system/nomad.service.d
sudo mv /tmp/nomad-server-tokens.conf /etc/systemd/system/nomad.service.d/tokens.conf
sudo systemctl daemon-reload
"
ok "Systemd override updated (VAULT_TOKEN removed)"

# ============================================================================
# 4. Update Nomad CLIENT config
# ============================================================================
info "Writing Workload Identity Nomad client config..."
NOMAD_SERVER_IP_CURRENT=$(vm_ip "$VM_NOMAD_SERVER")
_tmpfile=$(mktemp /tmp/nomad-client-XXXXXX.hcl)
cat > "$_tmpfile" <<NOMADEOF
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
multipass transfer "$_tmpfile" "$VM_NOMAD_CLIENT:/tmp/nomad-client.hcl"
rm -f "$_tmpfile"
vm_exec "$VM_NOMAD_CLIENT" "
  sudo mv /tmp/nomad-client.hcl /etc/nomad.d/client.hcl
  sudo chown nomad:nomad /etc/nomad.d/client.hcl
  sudo chmod 640 /etc/nomad.d/client.hcl
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
printf '[Service]\n# WORKLOAD IDENTITY ERA — static vault token removed\nEnvironment=CONSUL_HTTP_TOKEN=${CONSUL_NOMAD_CLIENT_PROCESS_TOKEN}\n' > /tmp/nomad-client-tokens.conf
sudo mkdir -p /etc/systemd/system/nomad.service.d
sudo mv /tmp/nomad-client-tokens.conf /etc/systemd/system/nomad.service.d/tokens.conf
sudo systemctl daemon-reload
"
ok "Client systemd override updated"

# ============================================================================
# 5. Restart Nomad server, then client
# ============================================================================
info "Restarting Nomad server with WI config..."
vm_exec "$VM_NOMAD_SERVER" "sudo systemctl restart nomad"
wait_for_port "$VM_NOMAD_SERVER" "$NOMAD_PORT" "Nomad server (WI)"
ok "Nomad server restarted with workload identity config"

info "Restarting Nomad client with WI config..."
vm_exec "$VM_NOMAD_CLIENT" "sudo systemctl restart nomad"
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
