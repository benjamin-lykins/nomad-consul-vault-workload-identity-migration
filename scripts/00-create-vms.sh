#!/usr/bin/env bash
# =============================================================================
# scripts/00-create-vms.sh
# Creates 4 Multipass VMs: vault-server, consul-server, nomad-server,
# nomad-client. Uses cloud-init/base.yaml for base provisioning.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

CLOUD_INIT="${REPO_ROOT}/cloud-init/base.yaml"
[[ -f "$CLOUD_INIT" ]] || die "cloud-init/base.yaml not found at $CLOUD_INIT"

create_vm() {
  local name="$1"
  if vm_exists "$name"; then
    warn "VM '${name}' already exists — skipping creation"
    vm_running "$name" || multipass start "$name"
  else
    info "Creating VM: ${name} (cpus=${VM_CPUS}, mem=${VM_MEM}, disk=${VM_DISK})"
    multipass launch "$VM_IMAGE" \
      --name       "$name"      \
      --cpus       "$VM_CPUS"   \
      --memory     "$VM_MEM"    \
      --disk       "$VM_DISK"   \
      --cloud-init "$CLOUD_INIT"
    ok "VM '${name}' created"
  fi
}

# ---------------------------------------------------------------------------
# Create all four VMs (sequentially — Multipass launch is not fully parallel)
# ---------------------------------------------------------------------------
info "=== Phase 0: Creating Multipass VMs ==="
create_vm "$VM_VAULT"
create_vm "$VM_CONSUL"
create_vm "$VM_NOMAD_SERVER"
create_vm "$VM_NOMAD_CLIENT"

# ---------------------------------------------------------------------------
# Wait for cloud-init to finish on all VMs
# ---------------------------------------------------------------------------
info "Waiting for cloud-init to complete on all VMs..."
for vm in "$VM_VAULT" "$VM_CONSUL" "$VM_NOMAD_SERVER" "$VM_NOMAD_CLIENT"; do
  wait_for_vm "$vm"
  info "Waiting for cloud-init on ${vm}..."
  vm_exec "$vm" "cloud-init status --wait" || true
  ok "cloud-init done on ${vm}"
done

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  VM Summary"
echo "============================================================"
for vm in "$VM_VAULT" "$VM_CONSUL" "$VM_NOMAD_SERVER" "$VM_NOMAD_CLIENT"; do
  ip=$(vm_ip "$vm")
  printf "  %-20s  %s\n" "$vm" "$ip"
done
echo "============================================================"
echo ""
echo "Next: run scripts/00b-setup-tls.sh"
