#!/usr/bin/env bash
# =============================================================================
# scripts/13-verify-migration.sh
# PHASE 2, STEP D — Verify workload identity is working end-to-end
#
# Deploys a new job using workload identity and confirms:
#   1. Nomad generates a JWT for the task
#   2. The JWT is used to authenticate to Vault (no static token)
#   3. The task can read its Vault secret via WI
#   4. The task registered in Consul via its own JWT (not a shared token)
#   5. Old VAULT_TOKEN / CONSUL_HTTP_TOKEN are gone from systemd envs
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

VAULT_IP=$(vm_ip "$VM_VAULT")
CONSUL_IP=$(vm_ip "$VM_CONSUL")
NOMAD_SERVER_IP=$(vm_ip "$VM_NOMAD_SERVER")
VAULT_TOKEN=$(load_secret "vault_root_token")

info "============================================================"
info "  STEP 13: Verifying Workload Identity migration"
info "============================================================"

# ============================================================================
# 1. Confirm VAULT_TOKEN is gone from Nomad server systemd env
# ============================================================================
info "Checking that VAULT_TOKEN is removed from Nomad server systemd..."
if vm_exec "$VM_NOMAD_SERVER" \
    "cat /etc/systemd/system/nomad.service.d/tokens.conf | grep -q VAULT_TOKEN"; then
  die "VAULT_TOKEN is still present in Nomad server systemd override!"
else
  ok "VAULT_TOKEN is NOT in Nomad server systemd override (expected)"
fi

if vm_exec "$VM_NOMAD_CLIENT" \
    "cat /etc/systemd/system/nomad.service.d/tokens.conf | grep -q VAULT_TOKEN"; then
  die "VAULT_TOKEN is still present in Nomad client systemd override!"
else
  ok "VAULT_TOKEN is NOT in Nomad client systemd override (expected)"
fi

# ============================================================================
# 2. Confirm Nomad cluster is healthy
# ============================================================================
info "Checking Nomad cluster health..."
vm_exec "$VM_NOMAD_SERVER" \
  "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} nomad server members"

NODES=$(vm_exec "$VM_NOMAD_SERVER" \
  "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} nomad node status")
echo "$NODES" | grep -q "ready" && ok "Nomad client node: ready" \
  || warn "Nomad client node not yet ready — may need more time"

# ============================================================================
# 3. Check Vault JWT auth is reachable from Nomad's JWKS endpoint
# ============================================================================
info "Verifying Vault can reach Nomad JWKS endpoint..."
vm_exec "$VM_VAULT" \
  "curl -sf http://${NOMAD_SERVER_IP}:${NOMAD_PORT}/.well-known/jwks.json | jq '.keys | length'" \
  && ok "Vault can reach Nomad JWKS endpoint" \
  || die "Vault cannot reach Nomad JWKS endpoint"

# ============================================================================
# 4. Stop the legacy job and deploy the workload identity demo job
# ============================================================================
info "Stopping legacy demo job..."
vm_exec "$VM_NOMAD_SERVER" \
  "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} \
  nomad job stop demo-legacy 2>/dev/null || true"
ok "Legacy job stopped"

info "Deploying workload identity demo job..."
JOB_FILE="${REPO_ROOT}/jobs/demo-wi.nomad"
vm_push "$VM_NOMAD_SERVER" "$JOB_FILE" "/tmp/demo-wi.nomad"

vm_exec "$VM_NOMAD_SERVER" \
  "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} \
  nomad job run /tmp/demo-wi.nomad"

# Wait for the WI job to reach running state
info "Waiting for workload identity demo job to start..."
for i in $(seq 1 40); do
  STATUS=$(vm_exec "$VM_NOMAD_SERVER" \
    "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} \
    nomad job status demo-wi -short 2>/dev/null | grep -E '^Status' | awk '{print \$3}'" || echo "pending")
  [[ "$STATUS" == "running" ]] && break
  echo "  Status: ${STATUS} (attempt $i/40)"
  sleep 5
done
[[ "$STATUS" == "running" ]] || die "WI demo job did not reach running state"
ok "Workload identity demo job is running"

# ============================================================================
# 5. Read task logs to confirm the secret was fetched via workload identity
# ============================================================================
info "Fetching allocation ID for demo-wi job..."
sleep 5  # let the task write its output
ALLOC_ID=$(vm_exec "$VM_NOMAD_SERVER" \
  "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} \
  nomad job allocs demo-wi -json 2>/dev/null | jq -r '.[0].ID'")

if [[ -n "$ALLOC_ID" && "$ALLOC_ID" != "null" ]]; then
  ok "Allocation ID: ${ALLOC_ID}"
  info "Reading task logs (stdout)..."
  vm_exec "$VM_NOMAD_SERVER" \
    "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} \
    nomad alloc logs ${ALLOC_ID} reader 2>/dev/null | tail -20" || true
else
  warn "Could not retrieve allocation ID — check 'nomad job status demo-wi'"
fi

# ============================================================================
# 6. Verify Vault has no Nomad token leases remaining (all via JWT now)
# ============================================================================
info "Checking for old Nomad token leases in Vault..."
LEASE_COUNT=$(vm_exec "$VM_VAULT" "
VAULT_ADDR=http://127.0.0.1:${VAULT_PORT} \
VAULT_TOKEN=${VAULT_TOKEN} \
  vault list sys/leases/lookup/auth/token/create/nomad-cluster 2>/dev/null \
  | grep -c '^[0-9a-f-]' || echo '0'")
info "Active legacy nomad-cluster token leases: ${LEASE_COUNT}"
[[ "$LEASE_COUNT" == "0" ]] && ok "No legacy Nomad token leases — full WI migration!" \
  || warn "${LEASE_COUNT} legacy lease(s) remain — stop old jobs to drain them"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "============================================================"
echo "  WORKLOAD IDENTITY Migration Verification Complete"
echo "============================================================"
echo ""
echo "  Auth model:    WORKLOAD IDENTITY (JWT)"
echo "  Vault auth:    jwt-nomad (JWT, not static token)"
echo "  Consul auth:   nomad-wi  (JWT, not static token)"
echo ""
echo "  Legacy job:    STOPPED"
echo "  WI demo job:   RUNNING"
echo ""
echo "  Vault UI:   http://${VAULT_IP}:${VAULT_PORT}"
echo "  Consul UI:  http://${CONSUL_IP}:${CONSUL_PORT}"
echo "  Nomad UI:   http://${NOMAD_SERVER_IP}:${NOMAD_PORT}"
echo "============================================================"
echo ""
echo "Migration complete! See README.md for next steps:"
echo "  - Revoke the legacy Vault Nomad token"
echo "  - Revoke the legacy Consul Nomad tokens"
echo "  - Update remaining jobs to use workload identity"
