#!/usr/bin/env bash
# =============================================================================
# scripts/04-install-nomad-client.sh
# Installs Nomad on the nomad-client VM (LEGACY config — token-based auth).
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

VM="$VM_NOMAD_CLIENT"
CLIENT_IP=$(vm_ip "$VM")
[[ -n "$CLIENT_IP" ]] || die "VM '${VM}' has no IP"

CONSUL_IP=$(vm_ip "$VM_CONSUL")
VAULT_IP=$(vm_ip "$VM_VAULT")
NOMAD_SERVER_IP=$(vm_ip "$VM_NOMAD_SERVER")

info "=== Installing Nomad ${NOMAD_VERSION} on ${VM} (${CLIENT_IP}) ==="

_NOMAD_PKG=$(ent_pkg "nomad" "${NOMAD_LICENSE_FILE:-}")
_NOMAD_APT_VER=$(ent_ver "$NOMAD_VERSION" "${NOMAD_LICENSE_FILE:-}")
_CONSUL_PKG=$(ent_pkg "consul" "${CONSUL_LICENSE_FILE:-}")
_CONSUL_APT_VER=$(ent_ver "$CONSUL_VERSION" "${CONSUL_LICENSE_FILE:-}")

# ---------------------------------------------------------------------------
# 1. Install Nomad + Consul agent
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
if ! sudo apt-get install -y ${_NOMAD_PKG}=${_NOMAD_APT_VER}-1 ${_CONSUL_PKG}=${_CONSUL_APT_VER}-1 2>/dev/null; then
  sudo apt-get install -y ${_NOMAD_PKG} ${_CONSUL_PKG}
fi
nomad version && consul version
"
ok "Nomad and Consul agent installed on client VM"

# ---------------------------------------------------------------------------
# 2. Directories + install enterprise licenses if provided
# ---------------------------------------------------------------------------
vm_exec "$VM" "
  sudo mkdir -p /opt/nomad/{data,plugins,alloc}
  sudo mkdir -p /opt/consul/data
  sudo chown -R nomad:nomad /opt/nomad
  sudo chown -R consul:consul /opt/consul
  # Tighten TLS key ownership now that the service users exist.
  sudo chown nomad:nomad /opt/tls/nomad-client.key
  sudo chmod 600 /opt/tls/nomad-client.key
  sudo cp /opt/tls/nomad-client.key /opt/tls/nomad-client-consul.key
  sudo chown consul:consul /opt/tls/nomad-client-consul.key
  sudo chmod 600 /opt/tls/nomad-client-consul.key
"
# Nomad Enterprise: license required on all nodes (server and client)
install_ent_license "$VM" "${NOMAD_LICENSE_FILE:-}" \
  "/etc/nomad.d/nomad.hclic" "nomad" "/etc/nomad.d/nomad.env" "NOMAD_LICENSE_PATH"
# Consul Enterprise: each agent node requires its own license
install_ent_license "$VM" "${CONSUL_LICENSE_FILE:-}" \
  "/etc/consul.d/consul.hclic" "consul" "/etc/consul.d/consul.env" "CONSUL_LICENSE_PATH"

# ---------------------------------------------------------------------------
# 3. Install Docker (Nomad jobs will use the docker driver in the demo)
# ---------------------------------------------------------------------------
info "Installing Docker on ${VM}..."
vm_exec "$VM" "
set -e
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
  https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -qq
sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo usermod -aG docker nomad
sudo systemctl enable docker
sudo systemctl start docker
"
ok "Docker installed"

# ---------------------------------------------------------------------------
# 4. Consul agent config (client mode)
# ---------------------------------------------------------------------------
GOSSIP_KEY=$(load_secret "consul_gossip_key")

cat <<EOF | multipass exec "$VM" -- bash -c "sudo tee /etc/consul.d/consul.hcl > /dev/null"
datacenter  = "dc1"
data_dir    = "/opt/consul/data"
log_level   = "INFO"
node_name   = "nomad-client"

server      = false
bind_addr   = "${CLIENT_IP}"
client_addr = "127.0.0.1"

retry_join  = ["${CONSUL_IP}"]
encrypt     = "${GOSSIP_KEY}"

ports {
  http     = -1
  https    = ${CONSUL_PORT}
  grpc     = 8502
  grpc_tls = -1
}

tls {
  defaults {
    ca_file                = "/opt/tls/ca.crt"
    cert_file              = "/opt/tls/nomad-client.crt"
    key_file               = "/opt/tls/nomad-client-consul.key"
    verify_incoming        = false
    verify_outgoing        = true
    verify_server_hostname = false
  }
}
EOF

vm_exec "$VM" "
  sudo chown consul:consul /etc/consul.d/consul.hcl
  sudo chmod 640 /etc/consul.d/consul.hcl
  sudo systemctl enable consul
  sudo systemctl restart consul
"
wait_for_port "$VM" "$CONSUL_PORT" "Consul agent (client)"

# ---------------------------------------------------------------------------
# 5. Write LEGACY Nomad client configuration
# ---------------------------------------------------------------------------
info "Writing LEGACY Nomad client configuration..."

# Remove the default config shipped by the package (has server mode enabled)
vm_exec "$VM" "sudo rm -f /etc/nomad.d/nomad.hcl"

cat <<NOMADEOF | multipass exec "$VM" -- bash -c "sudo tee /etc/nomad.d/client.hcl > /dev/null"
# /etc/nomad.d/client.hcl  (PHASE 1 — LEGACY TOKEN AUTH)
# -------------------------------------------------------------------

datacenter = "dc1"
data_dir   = "/opt/nomad/data"
log_level  = "INFO"
name       = "nomad-client"

bind_addr  = "0.0.0.0"

# This node is a client only
server {
  enabled = false
}

client {
  enabled = true

  server_join {
    retry_join = ["${NOMAD_SERVER_IP}:4647"]
  }

  # Host volumes for demos
  host_volume "data" {
    path      = "/opt/nomad/alloc"
    read_only = false
  }
}

# Consul integration — LEGACY token (injected via systemd env)
consul {
  address    = "127.0.0.1:8500"
  ssl        = true
  ca_file    = "/opt/tls/ca.crt"
  verify_ssl = true
}

# Vault integration — LEGACY token (injected via systemd env)
vault {
  enabled = true
  address = "https://${VAULT_IP}:${VAULT_PORT}"
  ca_file = "/opt/tls/ca.crt"
}

# TLS — HTTPS for Nomad API and RPC
tls {
  http      = true
  rpc       = true
  ca_file   = "/opt/tls/ca.crt"
  cert_file = "/opt/tls/nomad-client.crt"
  key_file  = "/opt/tls/nomad-client.key"
  verify_server_hostname = false
  verify_https_client    = false
}

# Enable Docker driver
plugin "docker" {
  config {
    allow_privileged = false
    volumes {
      enabled = true
    }
  }
}
NOMADEOF

vm_exec "$VM" "
  sudo chown nomad:nomad /etc/nomad.d/client.hcl
  sudo chmod 640 /etc/nomad.d/client.hcl
  sudo systemctl enable nomad
"
ok "=== Nomad client installed on ${CLIENT_IP} ==="
echo ""
echo "Next: run scripts/05-bootstrap.sh"
