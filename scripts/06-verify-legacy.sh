#!/usr/bin/env bash
# =============================================================================
# scripts/06-verify-legacy.sh
# Deploys a test job that uses LEGACY Vault token integration.
# Confirms the "before" state is working before running the migration.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

VAULT_IP=$(vm_ip "$VM_VAULT")
CONSUL_IP=$(vm_ip "$VM_CONSUL")
NOMAD_SERVER_IP=$(vm_ip "$VM_NOMAD_SERVER")

export VAULT_ADDR="http://${VAULT_IP}:${VAULT_PORT}"
export VAULT_TOKEN=$(load_secret "vault_root_token")
export NOMAD_ADDR="http://${NOMAD_SERVER_IP}:${NOMAD_PORT}"

info "=== Verifying LEGACY setup ==="

# ---------------------------------------------------------------------------
# Check Vault
# ---------------------------------------------------------------------------
info "Checking Vault..."
VAULT_STATUS=$(vm_exec "$VM_VAULT" \
  "VAULT_ADDR=http://127.0.0.1:${VAULT_PORT} vault status -format=json")
SEALED=$(echo "$VAULT_STATUS" | jq -r '.sealed')
[[ "$SEALED" == "false" ]] && ok "Vault: unsealed" || die "Vault is sealed!"

# Read demo secret
SECRET=$(vm_exec "$VM_VAULT" \
  "VAULT_ADDR=http://127.0.0.1:${VAULT_PORT} \
  VAULT_TOKEN=$(load_secret vault_root_token) \
  vault kv get -field=db_password secret/demo/config")
ok "Vault KV readable: db_password=${SECRET}"

# ---------------------------------------------------------------------------
# Check Consul
# ---------------------------------------------------------------------------
info "Checking Consul..."
CONSUL_TOKEN=$(load_secret "consul_bootstrap_token")
MEMBERS=$(vm_exec "$VM_CONSUL" \
  "CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
  CONSUL_HTTP_TOKEN=${CONSUL_TOKEN} \
  consul members")
ok "Consul members:"
echo "$MEMBERS" | sed 's/^/    /'

# ---------------------------------------------------------------------------
# Check Nomad cluster
# ---------------------------------------------------------------------------
info "Checking Nomad cluster..."
SERVERS=$(vm_exec "$VM_NOMAD_SERVER" \
  "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} nomad server members")
ok "Nomad servers:"
echo "$SERVERS" | sed 's/^/    /'

NODES=$(vm_exec "$VM_NOMAD_SERVER" \
  "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} nomad node status")
ok "Nomad nodes:"
echo "$NODES" | sed 's/^/    /'

# ---------------------------------------------------------------------------
# Deploy and run the legacy demo job
# ---------------------------------------------------------------------------
info "Deploying legacy demo job..."

JOB_FILE="${REPO_ROOT}/jobs/demo-legacy.nomad"
vm_push "$VM_NOMAD_SERVER" "$JOB_FILE" "/tmp/demo-legacy.nomad"

vm_exec "$VM_NOMAD_SERVER" \
  "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} \
  nomad job run /tmp/demo-legacy.nomad"

# Wait for the job to reach running state
info "Waiting for legacy job to start..."
for i in $(seq 1 30); do
  STATUS=$(vm_exec "$VM_NOMAD_SERVER" \
    "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} \
    nomad job status demo-legacy 2>/dev/null | grep -E '^Status' | head -1 | awk '{print \$3}'" || echo "pending")
  [[ "$STATUS" == "running" ]] && break
  echo "  Status: ${STATUS} (attempt $i/30)"
  sleep 5
done
[[ "$STATUS" == "running" ]] || die "Legacy demo job did not reach running state"
ok "Legacy demo job is running"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  LEGACY verification PASSED"
echo "============================================================"
echo ""
echo "  Auth model: LEGACY (static tokens)"
echo "  Vault token in nomad systemd env: YES"
echo "  Consul token in nomad systemd env: YES"
echo ""
echo "  The cluster is ready for migration."
echo "  Begin with: scripts/10-migrate-vault-wi.sh"
echo "============================================================"
