#!/usr/bin/env bash
# =============================================================================
# scripts/03-install-nomad-server.sh
# Installs Nomad on the nomad-server VM and writes the LEGACY server config
# (token-based Vault and Consul auth — this is the "before" state).
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

VM="$VM_NOMAD_SERVER"
NOMAD_IP=$(vm_ip "$VM")
[[ -n "$NOMAD_IP" ]] || die "VM '${VM}' has no IP"

CONSUL_IP=$(vm_ip "$VM_CONSUL")
VAULT_IP=$(vm_ip "$VM_VAULT")

info "=== Installing Nomad ${NOMAD_VERSION} on ${VM} (${NOMAD_IP}) ==="

# ---------------------------------------------------------------------------
# 1. Install Nomad (and consul agent for service registration)
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
if ! sudo apt-get install -y nomad=${NOMAD_VERSION}-1 consul=${CONSUL_VERSION}-1 2>/dev/null; then
  echo 'Exact version(s) not found, installing latest...'
  sudo apt-get install -y nomad consul
fi
nomad version
consul version
"
ok "Nomad and Consul agent installed"

# ---------------------------------------------------------------------------
# 2. Create directories
# ---------------------------------------------------------------------------
vm_exec "$VM" "
  sudo mkdir -p /opt/nomad/{data,plugins}
  sudo mkdir -p /opt/consul/data
  sudo chown -R nomad:nomad /opt/nomad
  sudo chown -R consul:consul /opt/consul
"

# ---------------------------------------------------------------------------
# 3. Install Consul agent config (client mode, joins consul-server)
# ---------------------------------------------------------------------------
GOSSIP_KEY=$(load_secret "consul_gossip_key")

cat <<EOF | multipass exec "$VM" -- bash -c "sudo tee /etc/consul.d/consul.hcl > /dev/null"
datacenter = "dc1"
data_dir   = "/opt/consul/data"
log_level  = "INFO"
node_name  = "nomad-server"

server     = false
bind_addr  = "${NOMAD_IP}"
client_addr = "127.0.0.1"

retry_join = ["${CONSUL_IP}"]

encrypt = "${GOSSIP_KEY}"

ports {
  grpc     = 8502
  grpc_tls = -1
}
EOF

vm_exec "$VM" "
  sudo chown consul:consul /etc/consul.d/consul.hcl
  sudo chmod 640 /etc/consul.d/consul.hcl
  sudo systemctl enable consul
  sudo systemctl restart consul
"
wait_for_port "$VM" "$CONSUL_PORT" "Consul agent"

# ---------------------------------------------------------------------------
# 4. Write LEGACY Nomad server configuration (token-based auth)
#    Placeholders will be filled in during 05-bootstrap.sh
# ---------------------------------------------------------------------------
info "Writing LEGACY Nomad server configuration..."
cat <<'NOMADEOF' | multipass exec "$VM" -- bash -c "sudo tee /etc/nomad.d/server.hcl > /dev/null"
# /etc/nomad.d/server.hcl  (PHASE 1 — LEGACY TOKEN AUTH)
# -------------------------------------------------------------------
# This is the "before" configuration.
# Nomad authenticates to Vault and Consul using long-lived tokens.
# These tokens are set by 05-bootstrap.sh via environment overrides.
# -------------------------------------------------------------------

datacenter = "dc1"
data_dir   = "/opt/nomad/data"
log_level  = "INFO"
name       = "nomad-server"

bind_addr = "0.0.0.0"

# Server configuration
server {
  enabled          = true
  bootstrap_expect = 1
}

# Consul integration — LEGACY token auth
# Token is injected via environment variable CONSUL_HTTP_TOKEN
# by the systemd override created in 05-bootstrap.sh
consul {
  address             = "127.0.0.1:8500"
  server_service_name = "nomad"
  client_service_name = "nomad-client"
  auto_advertise      = true
  server_auto_join    = true
  client_auto_join    = true
}

# Vault integration — LEGACY token auth
# VAULT_TOKEN is injected via the systemd override in 05-bootstrap.sh
vault {
  enabled          = true
  address          = "VAULT_ADDR_PLACEHOLDER"
  create_from_role = "nomad-cluster"
}
NOMADEOF

ok "Legacy Nomad server config written (Vault addr placeholder to be replaced)"

# ---------------------------------------------------------------------------
# 5. Replace Vault address placeholder
# ---------------------------------------------------------------------------
vm_exec "$VM" "sudo sed -i 's|VAULT_ADDR_PLACEHOLDER|http://${VAULT_IP}:${VAULT_PORT}|g' /etc/nomad.d/server.hcl"

vm_exec "$VM" "
  sudo chown nomad:nomad /etc/nomad.d/server.hcl
  sudo chmod 640 /etc/nomad.d/server.hcl
"

# ---------------------------------------------------------------------------
# 6. Enable Nomad — it will be started by 05-bootstrap.sh after tokens exist
# ---------------------------------------------------------------------------
vm_exec "$VM" "sudo systemctl enable nomad"
ok "=== Nomad server installed on ${NOMAD_IP} ==="
echo ""
echo "Next: run scripts/04-install-nomad-client.sh"
