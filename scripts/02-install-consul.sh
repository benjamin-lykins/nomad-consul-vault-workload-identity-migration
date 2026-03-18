#!/usr/bin/env bash
# =============================================================================
# scripts/02-install-consul.sh
# Installs Consul on the consul-server VM with ACLs enabled.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

VM="$VM_CONSUL"
CONSUL_IP=$(vm_ip "$VM")
[[ -n "$CONSUL_IP" ]] || die "VM '${VM}' has no IP"

NOMAD_SERVER_IP=$(vm_ip "$VM_NOMAD_SERVER")
NOMAD_CLIENT_IP=$(vm_ip "$VM_NOMAD_CLIENT")

info "=== Installing Consul ${CONSUL_VERSION} on ${VM} (${CONSUL_IP}) ==="

_CONSUL_PKG=$(ent_pkg "consul" "${CONSUL_LICENSE_FILE:-}")
_CONSUL_APT_VER=$(ent_ver "$CONSUL_VERSION" "${CONSUL_LICENSE_FILE:-}")

# ---------------------------------------------------------------------------
# 1. Install Consul
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
if ! sudo apt-get install -y ${_CONSUL_PKG}=${_CONSUL_APT_VER}-1 2>/dev/null; then
  echo 'Exact version not found, installing latest ${_CONSUL_PKG}...'
  sudo apt-get install -y ${_CONSUL_PKG}
fi
consul version
"
ok "Consul binary installed"

# ---------------------------------------------------------------------------
# 2. Generate gossip encryption key
# ---------------------------------------------------------------------------
GOSSIP_KEY=$(vm_exec "$VM" "consul keygen")
save_secret "consul_gossip_key" "$GOSSIP_KEY"
info "Gossip key generated and saved to ${SECRETS_DIR}/consul_gossip_key"

# ---------------------------------------------------------------------------
# 3. Create data directory
# ---------------------------------------------------------------------------
vm_exec "$VM" "
  sudo mkdir -p /opt/consul/{data,tls}
  sudo chown -R consul:consul /opt/consul
  # Tighten TLS key ownership now that the consul user exists
  sudo chown consul:consul /opt/tls/consul-server.key
  sudo chmod 600 /opt/tls/consul-server.key
"
install_ent_license "$VM" "${CONSUL_LICENSE_FILE:-}" \
  "/etc/consul.d/consul.hclic" "consul" "/etc/consul.d/consul.env" "CONSUL_LICENSE_PATH"

# ---------------------------------------------------------------------------
# 4. Write Consul server configuration
# ---------------------------------------------------------------------------
info "Writing Consul configuration..."
cat <<EOF | multipass exec "$VM" -- bash -c "sudo tee /etc/consul.d/consul.hcl > /dev/null"
# /etc/consul.d/consul.hcl
# -------------------------------------------------------------------
# Consul server — single node, ACLs enabled (development lab)
# -------------------------------------------------------------------

datacenter       = "dc1"
data_dir         = "/opt/consul/data"
log_level        = "INFO"
node_name        = "consul-server"

server           = true
bootstrap_expect = 1

bind_addr   = "${CONSUL_IP}"
client_addr = "0.0.0.0"

# Advertise the LAN address
advertise_addr = "${CONSUL_IP}"

ui_config {
  enabled = true
}

# ACLs — default deny, must explicitly grant access
acl {
  enabled                  = true
  default_policy           = "deny"
  enable_token_persistence = true
}

# Allow Nomad VMs to join the cluster
retry_join = ["${CONSUL_IP}"]

ports {
  http     = -1
  https    = ${CONSUL_PORT}
  grpc     = 8502
  grpc_tls = -1
}

# Gossip encryption
encrypt = "${GOSSIP_KEY}"

# TLS — HTTPS on all API and RPC connections
tls {
  defaults {
    ca_file                = "/opt/tls/ca.crt"
    cert_file              = "/opt/tls/consul-server.crt"
    key_file               = "/opt/tls/consul-server.key"
    verify_incoming        = false
    verify_outgoing        = true
    verify_server_hostname = false
  }
}
EOF

vm_exec "$VM" "sudo chown consul:consul /etc/consul.d/consul.hcl && sudo chmod 640 /etc/consul.d/consul.hcl"
ok "Consul config written"

# ---------------------------------------------------------------------------
# 5. Enable and start consul.service
# ---------------------------------------------------------------------------
vm_exec "$VM" "
  sudo systemctl daemon-reload
  sudo systemctl enable consul
  sudo systemctl restart consul
"
wait_for_port "$VM" "$CONSUL_PORT" "Consul API"
ok "=== Consul installed and running on https://${CONSUL_IP}:${CONSUL_PORT} ==="
echo ""
echo "Next: run scripts/03-install-nomad-server.sh"
