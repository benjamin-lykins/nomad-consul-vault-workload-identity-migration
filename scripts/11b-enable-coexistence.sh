#!/usr/bin/env bash
# =============================================================================
# scripts/11b-enable-coexistence.sh
# PHASE 2, STEP C — Enable Nomad coexistence mode (legacy + workload identity)
#
# Updates Nomad so that BOTH auth methods are active simultaneously:
#
#   Vault:  create_from_role (legacy, existing jobs)
#           jwt_auth_backend_path + default_identity (WI, new/redeployed jobs)
#
#   Consul: CONSUL_HTTP_TOKEN in systemd (Nomad process registration)
#           service_identity + task_identity in config (per-task JWT tokens)
#
# After this step existing jobs continue to use legacy tokens. Any newly
# scheduled or redeployed job automatically uses workload identity.
#
# Cutover (removing the legacy side) happens in: scripts/12-update-nomad-wi.sh
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

VAULT_IP=$(vm_ip "$VM_VAULT")
NOMAD_SERVER_IP=$(vm_ip "$VM_NOMAD_SERVER")

info "============================================================"
info "  STEP 11b: Enabling Nomad coexistence mode"
info "  (legacy token auth + workload identity simultaneously)"
info "============================================================"

CONSUL_BOOTSTRAP_TOKEN=$(load_secret "consul_bootstrap_token")

# ============================================================================
# 1. Ensure Consul auth method 'nomad-workloads' exists
#    Nomad 1.7+ looks for this exact name when deriving per-task Consul tokens.
# ============================================================================
info "Ensuring Consul auth method 'nomad-workloads' exists..."

# JWKSCAPEM requires CA cert content inline (not a file path)
vm_exec "$VM_CONSUL" "
CA_PEM=\$(sudo cat /opt/tls/ca.crt)
jq -n \
  --arg jwks_url 'https://${NOMAD_SERVER_IP}:${NOMAD_PORT}/.well-known/jwks.json' \
  --arg ca_pem \"\$CA_PEM\" \
  --argjson audiences '[\"${NOMAD_CONSUL_JWT_AUD}\"]' \
  '{
    JWKSURL: \$jwks_url,
    JWKSCACert: \$ca_pem,
    JWTSupportedAlgs: [\"RS256\"],
    BoundAudiences: \$audiences,
    ClaimMappings: {
      nomad_job_id:        \"nomad_job_id\",
      nomad_namespace:     \"nomad_namespace\",
      nomad_task:          \"nomad_task\",
      nomad_allocation_id: \"nomad_allocation_id\"
    }
  }' > /tmp/nomad-workloads-auth.json"

# Remove old 'nomad-wi' method if it exists from a previous run
vm_exec "$VM_CONSUL" "
for BR_ID in \$(CONSUL_HTTP_ADDR=https://127.0.0.1:${CONSUL_PORT} \
    CONSUL_CACERT=/opt/tls/ca.crt \
    CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
    consul acl binding-rule list -method nomad-wi -format json 2>/dev/null \
    | jq -r '.[].ID' 2>/dev/null); do
  CONSUL_HTTP_ADDR=https://127.0.0.1:${CONSUL_PORT} \
  CONSUL_CACERT=/opt/tls/ca.crt \
  CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
    consul acl binding-rule delete -id \"\$BR_ID\" 2>/dev/null || true
done
CONSUL_HTTP_ADDR=https://127.0.0.1:${CONSUL_PORT} \
CONSUL_CACERT=/opt/tls/ca.crt \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl auth-method delete -name nomad-wi 2>/dev/null || true
"

vm_exec "$VM_CONSUL" "
CONSUL_HTTP_ADDR=https://127.0.0.1:${CONSUL_PORT} \
CONSUL_CACERT=/opt/tls/ca.crt \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl auth-method create \
    -name 'nomad-workloads' \
    -type 'jwt' \
    -description 'Nomad Workload Identity JWT auth' \
    -config @/tmp/nomad-workloads-auth.json || \
CONSUL_HTTP_ADDR=https://127.0.0.1:${CONSUL_PORT} \
CONSUL_CACERT=/opt/tls/ca.crt \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl auth-method update \
    -name 'nomad-workloads' \
    -config @/tmp/nomad-workloads-auth.json
"

vm_exec "$VM_CONSUL" "
CONSUL_HTTP_ADDR=https://127.0.0.1:${CONSUL_PORT} \
CONSUL_CACERT=/opt/tls/ca.crt \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl binding-rule create \
    -method 'nomad-workloads' \
    -description 'Bind all Nomad workload JWTs to the nomad-workloads role' \
    -bind-type 'role' \
    -bind-name 'nomad-workloads' \
    -selector 'value.nomad_job_id != \"\"' 2>/dev/null || true
"
ok "Consul auth method 'nomad-workloads' ready"

# ============================================================================
# 2. Enable Consul ACLs on the Consul client agents running on Nomad VMs
#    Without this the local agent returns "ACL support disabled" and JWT
#    login fails at task startup.
# ============================================================================
info "Enabling Consul ACLs on Nomad VM agents..."
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
ok "Consul ACLs enabled on Nomad VM agents"

# ============================================================================
# 3. Create minimal Consul process tokens
#    Nomad's own service registration still needs a token; workload JWT tokens
#    cover task traffic only.
# ============================================================================
info "Creating minimal Consul process tokens for Nomad server and client..."
CONSUL_NOMAD_PROCESS_TOKEN=$(vm_exec "$VM_CONSUL" "
CONSUL_HTTP_ADDR=https://127.0.0.1:${CONSUL_PORT} \
CONSUL_CACERT=/opt/tls/ca.crt \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl token create \
    -description 'Nomad server process (minimal) — WI era' \
    -policy-name nomad-server \
    -format=json" | jq -r '.SecretID')
save_secret "consul_nomad_process_token" "$CONSUL_NOMAD_PROCESS_TOKEN"

CONSUL_NOMAD_CLIENT_PROCESS_TOKEN=$(vm_exec "$VM_CONSUL" "
CONSUL_HTTP_ADDR=https://127.0.0.1:${CONSUL_PORT} \
CONSUL_CACERT=/opt/tls/ca.crt \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl token create \
    -description 'Nomad client process (minimal) — WI era' \
    -policy-name nomad-client \
    -format=json" | jq -r '.SecretID')
save_secret "consul_nomad_client_process_token" "$CONSUL_NOMAD_CLIENT_PROCESS_TOKEN"
ok "Minimal Consul process tokens created"

# ============================================================================
# 4. Write coexistence Nomad SERVER config
#    Both create_from_role (legacy) and jwt_auth_backend_path (WI) are present.
# ============================================================================
info "Writing coexistence Nomad server config (legacy + WI)..."
_tmpfile=$(mktemp /tmp/nomad-server-XXXXXX.hcl)
cat > "$_tmpfile" <<NOMADEOF
# /etc/nomad.d/server.hcl  (PHASE 2 COEXISTENCE — legacy + workload identity)
# -------------------------------------------------------------------
# Both Vault auth methods are active simultaneously:
#
#   create_from_role      — legacy path. Nomad server generates child
#                           tokens from the nomad-cluster role for any
#                           job that does NOT carry a workload identity.
#                           Remove this in scripts/12-update-nomad-wi.sh.
#
#   jwt_auth_backend_path — WI path. New or redeployed jobs present a
#   default_identity        short-lived JWT to Vault's jwt-nomad method
#                           and receive a scoped service token.
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

# Consul — COEXISTENCE
# CONSUL_HTTP_TOKEN env var (minimal process token) handles Nomad's own
# service registration. Per-task tokens come from service/task_identity JWTs.
consul {
  address             = "127.0.0.1:8500"
  server_service_name = "nomad"
  client_service_name = "nomad-client"
  auto_advertise      = true
  server_auto_join    = true
  client_auto_join    = true
  ssl                 = true
  ca_file             = "/opt/tls/ca.crt"
  verify_ssl          = true

  service_identity {
    aud = ["${NOMAD_CONSUL_JWT_AUD}"]
    ttl = "1h"
  }
  task_identity {
    aud = ["${NOMAD_CONSUL_JWT_AUD}"]
    ttl = "1h"
  }
}

# Vault — COEXISTENCE (legacy token path + workload identity path both active)
vault {
  enabled = true
  address = "https://${VAULT_IP}:${VAULT_PORT}"
  ca_file = "/opt/tls/ca.crt"

  # Legacy: generates child tokens from this role for jobs without WI.
  # Removed during cutover in scripts/12-update-nomad-wi.sh.
  create_from_role = "nomad-cluster"

  # Workload identity: new/redeployed jobs authenticate via short-lived JWT.
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
ok "Coexistence Nomad server config written"

# ============================================================================
# 5. Write coexistence Nomad CLIENT config
# ============================================================================
info "Writing coexistence Nomad client config..."
NOMAD_SERVER_IP_CURRENT=$(vm_ip "$VM_NOMAD_SERVER")
_tmpfile=$(mktemp /tmp/nomad-client-XXXXXX.hcl)
cat > "$_tmpfile" <<NOMADEOF
# /etc/nomad.d/client.hcl  (PHASE 2 COEXISTENCE — legacy + workload identity)

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

# Consul — COEXISTENCE (process token in env, task JWT identities configured)
consul {
  address    = "127.0.0.1:8500"
  ssl        = true
  ca_file    = "/opt/tls/ca.crt"
  verify_ssl = true

  service_identity {
    aud = ["${NOMAD_CONSUL_JWT_AUD}"]
    ttl = "1h"
  }
  task_identity {
    aud = ["${NOMAD_CONSUL_JWT_AUD}"]
    ttl = "1h"
  }
}

# Vault — address only; WI config is inherited from the server
vault {
  enabled = true
  address = "https://${VAULT_IP}:${VAULT_PORT}"
  ca_file = "/opt/tls/ca.crt"
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
ok "Coexistence Nomad client config written"

# ============================================================================
# 6. Update systemd overrides
#    VAULT_TOKEN is kept — the legacy create_from_role path needs it.
#    CONSUL_HTTP_TOKEN is replaced with the minimal process token.
# ============================================================================
VAULT_NOMAD_SERVER_TOKEN=$(load_secret "vault_nomad_server_token")

info "Updating Nomad server systemd override (VAULT_TOKEN preserved for legacy)..."
vm_exec "$VM_NOMAD_SERVER" "
printf '[Service]\n# COEXISTENCE ERA — vault token kept for legacy jobs\nEnvironment=VAULT_TOKEN=${VAULT_NOMAD_SERVER_TOKEN}\nEnvironment=CONSUL_HTTP_TOKEN=${CONSUL_NOMAD_PROCESS_TOKEN}\n' > /tmp/nomad-server-tokens.conf
sudo mkdir -p /etc/systemd/system/nomad.service.d
sudo mv /tmp/nomad-server-tokens.conf /etc/systemd/system/nomad.service.d/tokens.conf
sudo systemctl daemon-reload
"
ok "Server systemd override updated"

info "Updating Nomad client systemd override (VAULT_TOKEN preserved for legacy)..."
vm_exec "$VM_NOMAD_CLIENT" "
printf '[Service]\n# COEXISTENCE ERA — vault token kept for legacy jobs\nEnvironment=VAULT_TOKEN=${VAULT_NOMAD_SERVER_TOKEN}\nEnvironment=CONSUL_HTTP_TOKEN=${CONSUL_NOMAD_CLIENT_PROCESS_TOKEN}\n' > /tmp/nomad-client-tokens.conf
sudo mkdir -p /etc/systemd/system/nomad.service.d
sudo mv /tmp/nomad-client-tokens.conf /etc/systemd/system/nomad.service.d/tokens.conf
sudo systemctl daemon-reload
"
ok "Client systemd override updated"

# ============================================================================
# 7. Restart Nomad
# ============================================================================
info "Restarting Nomad server with coexistence config..."
vm_exec "$VM_NOMAD_SERVER" "sudo systemctl restart nomad"
wait_for_port "$VM_NOMAD_SERVER" "$NOMAD_PORT" "Nomad server (coexistence)"
ok "Nomad server restarted"

info "Restarting Nomad client with coexistence config..."
vm_exec "$VM_NOMAD_CLIENT" "sudo systemctl restart nomad"
wait_for_port "$VM_NOMAD_CLIENT" "$NOMAD_PORT" "Nomad client (coexistence)"
ok "Nomad client restarted"

sleep 5
vm_exec "$VM_NOMAD_SERVER" \
  "NOMAD_ADDR=https://127.0.0.1:${NOMAD_PORT} NOMAD_CACERT=/opt/tls/ca.crt nomad server members"
ok "Nomad cluster healthy in coexistence mode"

echo ""
echo "============================================================"
echo "  Coexistence Mode Active"
echo "============================================================"
echo ""
echo "  Vault:  create_from_role (legacy) + jwt-nomad (WI) — both active"
echo "  Consul: process token (Nomad) + JWT identities (tasks)"
echo ""
echo "  Existing jobs: continue on legacy Vault tokens"
echo "  New/redeployed jobs: automatically use workload identity"
echo ""
echo "Next: scripts/12-update-nomad-wi.sh  ← removes legacy, completes cutover"
echo "============================================================"
