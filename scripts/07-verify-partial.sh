#!/usr/bin/env bash
# =============================================================================
# scripts/07-verify-partial.sh
# PHASE 2, STEP 2 — Verify the coexistence window before the Consul cutover
#
# Run this AFTER steps 10+11 but BEFORE step 12 (make migrate-nomad).
#
# Demonstrates the two different migration granularities:
#
#   Vault  (per-job, incremental):
#     demo-legacy  uses vault{ policies=[...] } + VAULT_TOKEN  → still works
#     demo-partial uses vault{ role="..." }    + WI JWT        → also works
#     Both run simultaneously. Each job independently opts in to Vault WI.
#
#   Consul (per-client, full cutover):
#     ALL services on this client still use the shared CONSUL_HTTP_TOKEN.
#     This is not a per-job choice — it is controlled by the Nomad client
#     config. Step 12 (make migrate-nomad) will flip ALL services on the
#     client to per-workload JWTs in a single client restart.
#
# Prerequisites:
#   make deploy          (Phase 1 complete)
#   make migrate-vault   (step 10 — Vault JWT auth configured)
#   make migrate-consul  (step 11 — Consul JWT auth configured)
#
# Do NOT run make migrate-nomad (step 12) before this script.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

VAULT_IP=$(vm_ip "$VM_VAULT")
CONSUL_IP=$(vm_ip "$VM_CONSUL")
NOMAD_SERVER_IP=$(vm_ip "$VM_NOMAD_SERVER")

info "============================================================"
info "  STEP 7: Coexistence window — Vault WI incremental,"
info "          Consul cutover pending (step 12 not yet run)"
info "============================================================"

# ============================================================================
# 1. Confirm demo-legacy is still running (deployed in step 6)
#    This proves legacy Vault token auth still works alongside WI
# ============================================================================
info "Checking demo-legacy (Vault=legacy token, Consul=shared token)..."
LEGACY_STATUS=$(vm_exec "$VM_NOMAD_SERVER" \
  "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} \
  nomad job status demo-legacy -short 2>/dev/null | grep -E '^Status' | awk '{print \$3}'" || echo "not found")

if [[ "$LEGACY_STATUS" == "running" ]]; then
  ok "demo-legacy: running — legacy Vault token auth is unaffected"
else
  warn "demo-legacy not running (${LEGACY_STATUS}) — re-deploying..."
  JOB_FILE="${REPO_ROOT}/jobs/demo-legacy.nomad"
  vm_push "$VM_NOMAD_SERVER" "$JOB_FILE" "/tmp/demo-legacy.nomad"
  vm_exec "$VM_NOMAD_SERVER" \
    "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} nomad job run /tmp/demo-legacy.nomad"
  for i in $(seq 1 30); do
    LEGACY_STATUS=$(vm_exec "$VM_NOMAD_SERVER" \
      "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} \
      nomad job status demo-legacy -short 2>/dev/null | grep -E '^Status' | awk '{print \$3}'" || echo "pending")
    [[ "$LEGACY_STATUS" == "running" ]] && break
    sleep 5
  done
  [[ "$LEGACY_STATUS" == "running" ]] || die "demo-legacy failed to start"
  ok "demo-legacy: running"
fi

# ============================================================================
# 2. Deploy demo-partial (Vault WI opted in, Consul still on shared token)
#    This job explicitly uses vault{ role="..." } + identity{} — WI for Vault.
#    Consul registration still uses the shared token because step 12 hasn't run.
# ============================================================================
info "Deploying demo-partial (Vault=WI, Consul=shared token pre-cutover)..."
JOB_FILE="${REPO_ROOT}/jobs/demo-partial.nomad"
vm_push "$VM_NOMAD_SERVER" "$JOB_FILE" "/tmp/demo-partial.nomad"

vm_exec "$VM_NOMAD_SERVER" \
  "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} \
  nomad job run /tmp/demo-partial.nomad"

info "Waiting for demo-partial to start..."
for i in $(seq 1 30); do
  PARTIAL_STATUS=$(vm_exec "$VM_NOMAD_SERVER" \
    "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} \
    nomad job status demo-partial -short 2>/dev/null | grep -E '^Status' | awk '{print \$3}'" || echo "pending")
  [[ "$PARTIAL_STATUS" == "running" ]] && break
  echo "  Status: ${PARTIAL_STATUS} (attempt $i/30)"
  sleep 5
done
[[ "$PARTIAL_STATUS" == "running" ]] || die "demo-partial did not reach running state"
ok "demo-partial: running — Vault WI is active, Consul cutover pending"

# ============================================================================
# 3. Show all running jobs
# ============================================================================
info "All running jobs:"
vm_exec "$VM_NOMAD_SERVER" \
  "NOMAD_ADDR=http://127.0.0.1:${NOMAD_PORT} nomad job status" | sed 's/^/    /'

# ============================================================================
# 4. Show Consul catalog — both services registered via shared token
# ============================================================================
info "Consul service catalog (all registrations via shared CONSUL_HTTP_TOKEN):"
CONSUL_TOKEN=$(load_secret "consul_bootstrap_token")
vm_exec "$VM_CONSUL" \
  "CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
  CONSUL_HTTP_TOKEN=${CONSUL_TOKEN} \
  consul catalog services" | sed 's/^/    /'

# ============================================================================
# 5. Summary
# ============================================================================
echo ""
echo "============================================================"
echo "  Coexistence window verified"
echo "============================================================"
echo ""
echo "  VAULT — per-job, incremental migration:"
echo "    demo-legacy   vault{ policies=[...] }  VAULT_TOKEN     running"
echo "    demo-partial  vault{ role='...' }       WI JWT          running"
echo "    Each job independently controls its Vault auth method."
echo "    Both work simultaneously — no forced cutover of existing jobs."
echo ""
echo "  CONSUL — per-client, full cutover (step 12):"
echo "    ALL jobs currently use the shared CONSUL_HTTP_TOKEN."
echo "    This is not a per-job setting. When step 12 (make migrate-nomad)"
echo "    restarts the Nomad client with service_identity configured,"
echo "    ALL services on this client switch to per-workload JWTs at once."
echo "    No job file changes are needed for Consul WI."
echo ""
echo "  Next: run make migrate-nomad (step 12) to trigger the Consul cutover"
echo "        and remove the legacy VAULT_TOKEN from Nomad."
echo "        Then run make verify-wi to confirm the full migration."
echo ""
echo "  Vault UI:    http://${VAULT_IP}:${VAULT_PORT}"
echo "  Consul UI:   http://${CONSUL_IP}:${CONSUL_PORT}"
echo "  Nomad UI:    http://${NOMAD_SERVER_IP}:${NOMAD_PORT}"
echo "============================================================"
