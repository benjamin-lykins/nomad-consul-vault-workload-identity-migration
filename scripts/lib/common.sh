#!/usr/bin/env bash
# =============================================================================
# scripts/lib/common.sh — Shared helpers for all migration scripts
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${REPO_ROOT}/env.sh"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
info() { echo -e "\033[0;34m[INFO ]\033[0m  $*"; }
ok()   { echo -e "\033[0;32m[ OK  ]\033[0m  $*"; }
warn() { echo -e "\033[0;33m[WARN ]\033[0m  $*"; }
die()  { echo -e "\033[0;31m[ERROR]\033[0m  $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Secrets directory — stores bootstrap tokens locally (never commit)
# ---------------------------------------------------------------------------
ensure_secrets_dir() {
  mkdir -p "${SECRETS_DIR}"
  chmod 700 "${SECRETS_DIR}"
}

save_secret() {
  local key="$1" value="$2"
  ensure_secrets_dir
  echo -n "$value" > "${SECRETS_DIR}/${key}"
  chmod 600 "${SECRETS_DIR}/${key}"
}

load_secret() {
  local key="$1"
  local path="${SECRETS_DIR}/${key}"
  [[ -f "$path" ]] || die "Secret '${key}' not found — did bootstrap complete?"
  cat "$path"
}

# ---------------------------------------------------------------------------
# Multipass helpers
# ---------------------------------------------------------------------------
vm_exists() {
  multipass info "$1" &>/dev/null
}

vm_running() {
  multipass info "$1" 2>/dev/null | grep -q "^State.*Running"
}

vm_ip() {
  multipass info "$1" 2>/dev/null | awk '/IPv4/ { print $2; exit }'
}

wait_for_vm() {
  local name="$1"
  info "Waiting for VM '${name}' to have an IP..."
  local ip=""
  for i in $(seq 1 30); do
    ip=$(vm_ip "$name")
    [[ -n "$ip" ]] && { ok "VM '${name}' is up at ${ip}"; return 0; }
    sleep 3
  done
  die "Timed out waiting for VM '${name}' to get an IP"
}

# Transfer a local file into a VM
vm_push() {
  local vm="$1" src="$2" dst="$3"
  multipass transfer "$src" "${vm}:${dst}"
}

# Run a command on a VM
vm_exec() {
  local vm="$1"; shift
  multipass exec "$vm" -- bash -c "$*"
}

# Run a here-doc script on a VM
vm_run_script() {
  local vm="$1" script="$2"
  multipass exec "$vm" -- bash -s < "$script"
}

# ---------------------------------------------------------------------------
# Wait for a TCP port to accept connections from inside the VM itself
# ---------------------------------------------------------------------------
wait_for_port() {
  local vm="$1" port="$2" label="${3:-service}"
  info "Waiting for ${label} on ${vm}:${port}..."
  for i in $(seq 1 40); do
    vm_exec "$vm" "nc -z 127.0.0.1 ${port} 2>/dev/null" && {
      ok "${label} is listening on port ${port}"
      return 0
    }
    sleep 3
  done
  die "Timed out waiting for ${label} on port ${port}"
}

# ---------------------------------------------------------------------------
# HashiCorp apt repo setup (run inside a VM)
# ---------------------------------------------------------------------------
HASHICORP_REPO_SCRIPT='
set -e
apt-get install -y gnupg curl lsb-release 2>/dev/null
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | tee /etc/apt/sources.list.d/hashicorp.list
apt-get update -y
'

export HASHICORP_REPO_SCRIPT

# ---------------------------------------------------------------------------
# TLS — cert paths on VMs (populated by 00b-setup-tls.sh)
# ---------------------------------------------------------------------------
TLS_DIR_VM="/opt/tls"
TLS_CA_VM="${TLS_DIR_VM}/ca.crt"

# ---------------------------------------------------------------------------
# Enterprise helpers
# ---------------------------------------------------------------------------

# Return the apt package name: <base>-enterprise if a license file exists, else <base>
# Usage: pkg=$(ent_pkg "vault" "${VAULT_LICENSE_FILE:-}")
ent_pkg() {
  local base="$1" license_file="${2:-}"
  [[ -n "$license_file" && -f "$license_file" ]] && echo "${base}-enterprise" || echo "${base}"
}

# Return the apt version string: <ver>+ent if a license file exists, else <ver>
# Usage: ver=$(ent_ver "$VAULT_VERSION" "${VAULT_LICENSE_FILE:-}")
ent_ver() {
  local version="$1" license_file="${2:-}"
  [[ -n "$license_file" && -f "$license_file" ]] && echo "${version}+ent" || echo "${version}"
}

# Copy a license file to a VM and write a license_path config fragment.
# No-op if LICENSE_FILE is empty or the file does not exist.
# Usage: install_ent_license "$VM" "${VAULT_LICENSE_FILE:-}" \
#          /etc/vault.d/vault.hclic vault /etc/vault.d
install_ent_license() {
  local vm="$1" license_file="${2:-}" dst="$3" owner="$4" env_file="$5" env_var="$6"
  [[ -z "$license_file" || ! -f "$license_file" ]] && return 0
  info "Installing enterprise license on ${vm}..."
  multipass transfer "$license_file" "${vm}:/tmp/ent.hclic"
  vm_exec "$vm" "
    sudo mv /tmp/ent.hclic ${dst}
    sudo chown ${owner}:${owner} ${dst}
    sudo chmod 640 ${dst}
    echo '${env_var}=${dst}' | sudo tee ${env_file} > /dev/null
  "
  ok "Enterprise license installed on ${vm}:${dst}"
}
