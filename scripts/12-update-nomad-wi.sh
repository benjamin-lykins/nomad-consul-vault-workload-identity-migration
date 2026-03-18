#!/usr/bin/env bash
# =============================================================================
# scripts/12-update-nomad-wi.sh
# PHASE 2, STEP D — Workload Identity cutover (removes legacy Vault auth)
#
# Prerequisite: scripts/11b-enable-coexistence.sh must have run first.
#
# What this script removes from the coexistence config:
#   - vault.create_from_role  (Nomad no longer generates child tokens)
#   - VAULT_TOKEN from systemd overrides
#
# After this step Nomad has NO static Vault token anywhere. All task Vault
# access goes through short-lived JWTs issued per allocation.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

VAULT_IP=$(vm_ip "$VM_VAULT")

CONSUL_NOMAD_PROCESS_TOKEN=$(load_secret "consul_nomad_process_token")
CONSUL_NOMAD_CLIENT_PROCESS_TOKEN=$(load_secret "consul_nomad_client_process_token")

info "============================================================"
info "  STEP 12: Workload Identity cutover"
info "  (removing legacy Vault token auth)"
info "============================================================"

# ============================================================================
# 1. Write final Nomad SERVER config — create_from_role removed
# ============================================================================
info "Writing final Nomad server config (WI only)..."
_tmpfile=$(mktemp /tmp/nomad-server-XXXXXX.hcl)
cat > "$_tmpfile" <<NOMADEOF
# /etc/nomad.d/server.hcl  (PHASE 2 COMPLETE — workload identity only)
# create_from_role removed — Nomad no longer holds a static Vault token.
# All task Vault access is via short-lived JWTs (jwt-nomad auth method).

datacenter = "dc1"
data_dir   = "/opt/nomad/data"
log_level  = "INFO"
name       = "nomad-server"

bind_addr = "0.0.0.0"

server {
  enabled          = true
  bootstrap_expect = 1
}

consul {
  address             = "127.0.0.1:8500"
  server_service_name = "nomad"
  client_service_name = "nomad-client"
  auto_advertise      = true
  server_auto_join    = true
  client_auto_join    = true

  service_identity {
    aud = ["${NOMAD_CONSUL_JWT_AUD}"]
    ttl = "1h"
  }
  task_identity {
    aud = ["${NOMAD_CONSUL_JWT_AUD}"]
    ttl = "1h"
  }
}

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
ok "Final Nomad server config written (no create_from_role)"

# ============================================================================
# 2. Update systemd overrides — remove VAULT_TOKEN
#    CONSUL_HTTP_TOKEN stays (Nomad's own service registration still needs it)
# ============================================================================
info "Removing VAULT_TOKEN from Nomad server systemd override..."
vm_exec "$VM_NOMAD_SERVER" "
printf '[Service]\n# WORKLOAD IDENTITY ERA — static vault token removed\n# Consul token is still needed for Nomad server own service registration.\nEnvironment=CONSUL_HTTP_TOKEN=${CONSUL_NOMAD_PROCESS_TOKEN}\n' > /tmp/nomad-server-tokens.conf
sudo mkdir -p /etc/systemd/system/nomad.service.d
sudo mv /tmp/nomad-server-tokens.conf /etc/systemd/system/nomad.service.d/tokens.conf
sudo systemctl daemon-reload
"
ok "VAULT_TOKEN removed from server systemd override"

info "Removing VAULT_TOKEN from Nomad client systemd override..."
vm_exec "$VM_NOMAD_CLIENT" "
printf '[Service]\n# WORKLOAD IDENTITY ERA — static vault token removed\nEnvironment=CONSUL_HTTP_TOKEN=${CONSUL_NOMAD_CLIENT_PROCESS_TOKEN}\n' > /tmp/nomad-client-tokens.conf
sudo mkdir -p /etc/systemd/system/nomad.service.d
sudo mv /tmp/nomad-client-tokens.conf /etc/systemd/system/nomad.service.d/tokens.conf
sudo systemctl daemon-reload
"
ok "VAULT_TOKEN removed from client systemd override"

# ============================================================================
# 3. Restart Nomad
# ============================================================================
info "Restarting Nomad server..."
vm_exec "$VM_NOMAD_SERVER" "sudo systemctl restart nomad"
wait_for_port "$VM_NOMAD_SERVER" "$NOMAD_PORT" "Nomad server (WI)"
ok "Nomad server restarted"

info "Restarting Nomad client..."
vm_exec "$VM_NOMAD_CLIENT" "sudo systemctl restart nomad"
wait_for_port "$VM_NOMAD_CLIENT" "$NOMAD_PORT" "Nomad client (WI)"
ok "Nomad client restarted"

sleep 5
vm_exec "$VM_NOMAD_SERVER" \
  "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} nomad server members"
ok "Nomad cluster members verified"

echo ""
echo "============================================================"
echo "  Nomad Workload Identity Cutover Complete"
echo "============================================================"
echo ""
echo "  Vault auth:   JWT via jwt-nomad (no static VAULT_TOKEN)"
echo "  Consul auth:  JWT via nomad-workloads (no static CONSUL_HTTP_TOKEN for tasks)"
echo ""
echo "Next: scripts/13-verify-migration.sh"
echo "============================================================"
