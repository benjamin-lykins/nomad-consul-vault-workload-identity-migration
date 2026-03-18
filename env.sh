#!/usr/bin/env bash
# =============================================================================
# env.sh — Environment variables for the Nomad workload identity migration lab
# Source this file before running any script: source env.sh
# =============================================================================

# ---------------------------------------------------------------------------
# Software versions
# NOTE: Vault patch versions follow semantic versioning (MAJOR.MINOR.PATCH).
#       Adjust to the exact build available at releases.hashicorp.com.
# ---------------------------------------------------------------------------
export VAULT_VERSION="1.16.3"    # User requested 1.16.26 — use closest available
export CONSUL_VERSION="1.21.5"
export NOMAD_VERSION="1.8.4"

# ---------------------------------------------------------------------------
# Enterprise licenses (optional — leave empty to use Community Edition)
# Set each to the path of a .hclic file on your host machine.
# If the file is absent or the variable is empty, CE packages are used.
# ---------------------------------------------------------------------------
export VAULT_LICENSE_FILE="/license/vault.hclic"    # e.g., /path/to/vault.hclic
export CONSUL_LICENSE_FILE="/license/consul.hclic"   # e.g., /path/to/consul.hclic
export NOMAD_LICENSE_FILE="/license/nomad.hclic"    # e.g., /path/to/nomad.hclic

# ---------------------------------------------------------------------------
# Multipass VM names
# ---------------------------------------------------------------------------
export VM_VAULT="vault-server"
export VM_CONSUL="consul-server"
export VM_NOMAD_SERVER="nomad-server"
export VM_NOMAD_CLIENT="nomad-client"

# ---------------------------------------------------------------------------
# Multipass VM resources
# ---------------------------------------------------------------------------
export VM_CPUS="2"
export VM_MEM="2G"
export VM_DISK="10G"
export VM_IMAGE="22.04"   # Ubuntu LTS

# ---------------------------------------------------------------------------
# Ports (defaults — must match config files)
# ---------------------------------------------------------------------------
export VAULT_PORT="8200"
export CONSUL_PORT="8500"
export NOMAD_PORT="4646"

# ---------------------------------------------------------------------------
# Nomad workload identity JWT audience values
# These must match the audience configured in Vault and Consul JWT auth methods
# ---------------------------------------------------------------------------
export NOMAD_VAULT_JWT_AUD="vault.io"
export NOMAD_CONSUL_JWT_AUD="consul.io"

# ---------------------------------------------------------------------------
# Paths (on the host) for storing bootstrap secrets
# ---------------------------------------------------------------------------
export SECRETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.secrets"

# ---------------------------------------------------------------------------
# Helper: get the IP of a Multipass VM
# Usage: vm_ip vault-server
# ---------------------------------------------------------------------------
vm_ip() {
  multipass info "$1" 2>/dev/null \
    | awk '/IPv4/ { print $2; exit }'
}

# Lazy-evaluated VM IPs (populated after VMs start)
vault_ip()        { vm_ip "$VM_VAULT"; }
consul_ip()       { vm_ip "$VM_CONSUL"; }
nomad_server_ip() { vm_ip "$VM_NOMAD_SERVER"; }
nomad_client_ip() { vm_ip "$VM_NOMAD_CLIENT"; }
