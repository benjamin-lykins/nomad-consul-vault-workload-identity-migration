#!/usr/bin/env bash
# =============================================================================
# scripts/01-install-vault.sh
# Installs Vault on the vault-server VM and drops a starter config.
# Run AFTER 00-create-vms.sh.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

VM="$VM_VAULT"
VAULT_IP=$(vm_ip "$VM")
[[ -n "$VAULT_IP" ]] || die "VM '${VM}' has no IP — did 00-create-vms.sh complete?"

info "=== Installing Vault ${VAULT_VERSION} on ${VM} (${VAULT_IP}) ==="

# ---------------------------------------------------------------------------
# 1. Install Vault via HashiCorp apt repo
# ---------------------------------------------------------------------------
vm_exec "$VM" "
set -e
export DEBIAN_FRONTEND=noninteractive
sudo apt-get install -y gnupg curl lsb-release 2>&1 | tail -5
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo \"deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com \$(lsb_release -cs) main\" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
sudo apt-get update -qq
# Install exact version; fall back to latest in the series if not found
if ! sudo apt-get install -y vault=${VAULT_VERSION}-1 2>/dev/null; then
  echo 'Exact version not found, installing latest vault...'
  sudo apt-get install -y vault
fi
vault version
"
ok "Vault binary installed"

# ---------------------------------------------------------------------------
# 2. Create directories
# ---------------------------------------------------------------------------
vm_exec "$VM" "
  sudo mkdir -p /opt/vault/{data,tls,plugins}
  sudo chown -R vault:vault /opt/vault
  sudo chmod 750 /opt/vault/data
  # Tighten TLS key ownership now that the vault user exists
  sudo chown vault:vault /opt/tls/vault-server.key
  sudo chmod 600 /opt/tls/vault-server.key
"

# ---------------------------------------------------------------------------
# 3. Write Vault configuration
# ---------------------------------------------------------------------------
info "Writing Vault configuration..."
cat <<EOF | multipass exec "$VM" -- bash -c "sudo tee /etc/vault.d/vault.hcl > /dev/null"
# /etc/vault.d/vault.hcl
# -------------------------------------------------------------------
# Vault server configuration — single node Raft (development lab)
# -------------------------------------------------------------------

ui            = true
disable_mlock = true
log_level     = "info"

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "vault-1"
}

listener "tcp" {
  address       = "0.0.0.0:${VAULT_PORT}"
  tls_cert_file = "/opt/tls/vault-server.crt"
  tls_key_file  = "/opt/tls/vault-server.key"
}

api_addr     = "https://${VAULT_IP}:${VAULT_PORT}"
cluster_addr = "https://${VAULT_IP}:8201"
EOF

vm_exec "$VM" "sudo chown vault:vault /etc/vault.d/vault.hcl && sudo chmod 640 /etc/vault.d/vault.hcl"
ok "Vault config written"

# ---------------------------------------------------------------------------
# 4. Enable and start vault.service
# ---------------------------------------------------------------------------
vm_exec "$VM" "
  sudo systemctl daemon-reload
  sudo systemctl enable vault
  sudo systemctl restart vault
"
wait_for_port "$VM" "$VAULT_PORT" "Vault API"
ok "=== Vault installed and running on https://${VAULT_IP}:${VAULT_PORT} ==="
echo ""
echo "Next: run scripts/02-install-consul.sh"
