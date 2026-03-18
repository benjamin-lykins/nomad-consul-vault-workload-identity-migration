#!/usr/bin/env bash
# =============================================================================
# scripts/00b-setup-tls.sh
# Generate a self-signed CA + per-VM TLS certificates, then distribute them.
# Run AFTER 00-create-vms.sh, BEFORE 01-install-vault.sh.
#
# Certificate layout (on each VM):
#   /opt/tls/ca.crt              — trusted root CA
#   /opt/tls/<vm-name>.crt       — server certificate (IP + DNS SANs)
#   /opt/tls/<vm-name>.key       — private key (mode 600)
#
# Host copies are saved to .secrets/tls/ (never commit).
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

command -v openssl >/dev/null 2>&1 || die "openssl is required but not found"

TLS_DIR="${SECRETS_DIR}/tls"
TLS_DAYS=730   # 2-year cert lifetime

mkdir -p "$TLS_DIR"
chmod 700 "$TLS_DIR"

info "=== Generating TLS certificates for the lab ==="

# ---------------------------------------------------------------------------
# 1. Root CA (generated once; reused on subsequent runs)
# ---------------------------------------------------------------------------
if [[ ! -f "${TLS_DIR}/ca.key" ]]; then
  info "Generating root CA..."
  openssl genrsa -out "${TLS_DIR}/ca.key" 4096 2>/dev/null
  openssl req -x509 -new -nodes \
    -key  "${TLS_DIR}/ca.key" \
    -sha256 -days ${TLS_DAYS} \
    -subj "/CN=Lab-CA/O=Nomad-WI-Lab" \
    -out  "${TLS_DIR}/ca.crt"
  ok "Root CA generated"
else
  ok "Root CA already exists — reusing"
fi

# ---------------------------------------------------------------------------
# 2. Helper: generate a server cert signed by the CA with IP + DNS SANs
# ---------------------------------------------------------------------------
generate_cert() {
  local name="$1"   # e.g. "vault-server"
  local ip="$2"     # primary VM IP

  info "Generating cert for ${name} (IP: ${ip})..."

  # Extension file used for both CSR and final signing
  cat > "${TLS_DIR}/${name}.ext" <<EXTEOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name

[req_distinguished_name]

[v3_req]
subjectAltName = @alt_names
keyUsage = critical, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth

[alt_names]
IP.1 = ${ip}
IP.2 = 127.0.0.1
DNS.1 = localhost
DNS.2 = ${name}
EXTEOF

  openssl genrsa -out "${TLS_DIR}/${name}.key" 2048 2>/dev/null
  openssl req -new \
    -key    "${TLS_DIR}/${name}.key" \
    -subj   "/CN=${name}/O=Nomad-WI-Lab" \
    -config "${TLS_DIR}/${name}.ext" \
    -out    "${TLS_DIR}/${name}.csr"
  openssl x509 -req \
    -in      "${TLS_DIR}/${name}.csr" \
    -CA      "${TLS_DIR}/ca.crt" \
    -CAkey   "${TLS_DIR}/ca.key" \
    -CAcreateserial \
    -out     "${TLS_DIR}/${name}.crt" \
    -days    ${TLS_DAYS} \
    -sha256 \
    -extfile "${TLS_DIR}/${name}.ext" \
    -extensions v3_req 2>/dev/null

  rm -f "${TLS_DIR}/${name}.csr" "${TLS_DIR}/${name}.ext"
  ok "Cert generated for ${name}"
}

# ---------------------------------------------------------------------------
# 3. Collect VM IPs and generate a cert per VM
# ---------------------------------------------------------------------------
info "Collecting VM IPs..."
VAULT_IP=$(vm_ip "$VM_VAULT")
CONSUL_IP=$(vm_ip "$VM_CONSUL")
NOMAD_SERVER_IP=$(vm_ip "$VM_NOMAD_SERVER")
NOMAD_CLIENT_IP=$(vm_ip "$VM_NOMAD_CLIENT")

[[ -n "$VAULT_IP" ]]        || die "No IP for ${VM_VAULT} — is it running?"
[[ -n "$CONSUL_IP" ]]       || die "No IP for ${VM_CONSUL} — is it running?"
[[ -n "$NOMAD_SERVER_IP" ]] || die "No IP for ${VM_NOMAD_SERVER} — is it running?"
[[ -n "$NOMAD_CLIENT_IP" ]] || die "No IP for ${VM_NOMAD_CLIENT} — is it running?"

generate_cert "vault-server"  "$VAULT_IP"
generate_cert "consul-server" "$CONSUL_IP"
generate_cert "nomad-server"  "$NOMAD_SERVER_IP"
generate_cert "nomad-client"  "$NOMAD_CLIENT_IP"

# ---------------------------------------------------------------------------
# 4. Distribute certs to each VM
# ---------------------------------------------------------------------------
distribute_certs() {
  local vm="$1"
  local cert_name="$2"

  info "Distributing TLS certs to ${vm}..."

  vm_exec "$vm" "sudo mkdir -p /opt/tls && sudo chmod 755 /opt/tls"

  multipass transfer "${TLS_DIR}/ca.crt"              "${vm}:/tmp/ca.crt"
  multipass transfer "${TLS_DIR}/${cert_name}.crt"    "${vm}:/tmp/${cert_name}.crt"
  multipass transfer "${TLS_DIR}/${cert_name}.key"    "${vm}:/tmp/${cert_name}.key"

  vm_exec "$vm" "
    sudo mv /tmp/ca.crt           /opt/tls/ca.crt
    sudo mv /tmp/${cert_name}.crt /opt/tls/${cert_name}.crt
    sudo mv /tmp/${cert_name}.key /opt/tls/${cert_name}.key
    sudo chmod 644 /opt/tls/ca.crt /opt/tls/${cert_name}.crt
    sudo chmod 600 /opt/tls/${cert_name}.key
    sudo chown root:root /opt/tls/ca.crt /opt/tls/${cert_name}.crt /opt/tls/${cert_name}.key
  "

  # Add CA to the system trust store so all tools trust it automatically
  vm_exec "$vm" "
    sudo cp /opt/tls/ca.crt /usr/local/share/ca-certificates/lab-ca.crt
    sudo update-ca-certificates --fresh 2>&1 | tail -3
  "

  ok "TLS certs distributed to ${vm}"
}

distribute_certs "$VM_VAULT"        "vault-server"
distribute_certs "$VM_CONSUL"       "consul-server"
distribute_certs "$VM_NOMAD_SERVER" "nomad-server"
distribute_certs "$VM_NOMAD_CLIENT" "nomad-client"

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  TLS Certificate Setup Complete"
echo "============================================================"
echo ""
echo "  Root CA:   ${TLS_DIR}/ca.crt"
echo "  VM certs:  /opt/tls/<vm-name>.{crt,key} on each VM"
echo "  CA trusted system-wide on all VMs"
echo ""
echo "  vault-server:  /opt/tls/vault-server.{crt,key}"
echo "  consul-server: /opt/tls/consul-server.{crt,key}"
echo "  nomad-server:  /opt/tls/nomad-server.{crt,key}"
echo "  nomad-client:  /opt/tls/nomad-client.{crt,key}"
echo ""
echo "Next: run scripts/01-install-vault.sh"
echo "============================================================"
