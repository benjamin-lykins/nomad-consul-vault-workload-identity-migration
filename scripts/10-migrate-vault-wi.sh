#!/usr/bin/env bash
# =============================================================================
# scripts/10-migrate-vault-wi.sh
# PHASE 2, STEP A — Configure Vault to accept Nomad Workload Identity JWTs
#
# What changes on Vault:
#   - Enable JWT auth method at path "jwt-nomad"
#   - Point JWKS URL at Nomad's OIDC discovery endpoint
#   - Create a Vault role that maps Nomad JWT claims to policies
#   - Create new workload-identity-aware policy (replaces legacy role-based policy)
#   - NO changes to Nomad config yet (Nomad still uses legacy token)
#
# Why this order:
#   Vault must be ready to accept WI JWTs BEFORE Nomad is reconfigured.
#   This lets you do a zero-downtime migration — existing jobs keep working
#   with the legacy token while the new JWT path is being validated.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

VAULT_IP=$(vm_ip "$VM_VAULT")
NOMAD_SERVER_IP=$(vm_ip "$VM_NOMAD_SERVER")
VAULT_ADDR="http://${VAULT_IP}:${VAULT_PORT}"
VAULT_TOKEN=$(load_secret "vault_root_token")

info "============================================================"
info "  STEP 10: Configuring Vault JWT auth for Workload Identity"
info "============================================================"

# ============================================================================
# 1. Enable JWT auth method at a dedicated path for Nomad
# ============================================================================
info "Enabling JWT auth method at path 'jwt-nomad'..."
vm_exec "$VM_VAULT" "
VAULT_ADDR=http://127.0.0.1:${VAULT_PORT} \
VAULT_TOKEN=${VAULT_TOKEN} \
  vault auth enable -path=jwt-nomad jwt 2>/dev/null \
    && echo 'JWT auth enabled' \
    || echo 'JWT auth already enabled (skipping)'
"
ok "JWT auth method at 'jwt-nomad' is ready"

# ============================================================================
# 2. Configure the JWT auth method with Nomad's OIDC discovery URL
#    Nomad exposes JWKS at /.well-known/jwks.json on the HTTP API
# ============================================================================
info "Configuring JWT auth with Nomad OIDC/JWKS..."
vm_exec "$VM_VAULT" "
VAULT_ADDR=http://127.0.0.1:${VAULT_PORT} \
VAULT_TOKEN=${VAULT_TOKEN} \
  vault write auth/jwt-nomad/config \
    jwks_url='http://${NOMAD_SERVER_IP}:${NOMAD_PORT}/.well-known/jwks.json' \
    default_role='nomad-workloads'
"
ok "JWT auth configured with Nomad JWKS endpoint"

# ============================================================================
# 3. Create Vault policy for workload identity (replaces legacy policy)
#    Note: policies stay the same — what changes is HOW they are granted
# ============================================================================
info "Creating Vault policy 'nomad-workloads-wi'..."
vm_exec "$VM_VAULT" "cat > /tmp/nomad-workloads-wi-policy.hcl << 'POLICY'
# nomad-workloads-wi — granted via JWT workload identity (not legacy token role)
#
# Workloads can read their own secrets scoped by namespace and job name.
# The {{identity.entity.aliases.MOUNT_ACCESSOR.metadata.nomad_namespace}}
# template syntax uses claims from the JWT to scope access.

# Read demo secrets (broad access for lab — scope tighter in production)
path \"secret/data/demo/*\" {
  capabilities = [\"read\"]
}
path \"secret/metadata/demo/*\" {
  capabilities = [\"list\", \"read\"]
}

# Allow workloads to look up their own token info
path \"auth/token/lookup-self\" {
  capabilities = [\"read\"]
}
POLICY
VAULT_ADDR=http://127.0.0.1:${VAULT_PORT} \
VAULT_TOKEN=${VAULT_TOKEN} \
  vault policy write nomad-workloads-wi /tmp/nomad-workloads-wi-policy.hcl
"
ok "Vault policy 'nomad-workloads-wi' created"

# ============================================================================
# 4. Create JWT role for Nomad workloads
#    bound_audiences must match the 'aud' in Nomad's workload_identity config
#    user_claim is used as the entity alias in Vault
# ============================================================================
info "Creating JWT role 'nomad-workloads'..."
vm_exec "$VM_VAULT" "
VAULT_ADDR=http://127.0.0.1:${VAULT_PORT} \
VAULT_TOKEN=${VAULT_TOKEN} \
  vault write auth/jwt-nomad/role/nomad-workloads \
    role_type='jwt' \
    bound_audiences='${NOMAD_VAULT_JWT_AUD}' \
    user_claim='/nomad_job_id' \
    claim_mappings='/nomad_job_id=nomad_job_id' \
    claim_mappings='/nomad_namespace=nomad_namespace' \
    claim_mappings='/nomad_task=nomad_task' \
    claim_mappings='/nomad_allocation_id=nomad_allocation_id' \
    token_type='service' \
    token_policies='nomad-workloads-wi' \
    token_period='30m' \
    token_explicit_max_ttl='0' \
    token_no_default_policy='true'
"
ok "JWT role 'nomad-workloads' created"

# ============================================================================
# 5. Verify the configuration
# ============================================================================
info "Verifying JWT auth configuration..."
vm_exec "$VM_VAULT" "
VAULT_ADDR=http://127.0.0.1:${VAULT_PORT} \
VAULT_TOKEN=${VAULT_TOKEN} \
  vault read auth/jwt-nomad/config
"
ok "Vault JWT auth configuration verified"

echo ""
echo "============================================================"
echo "  Vault Workload Identity Configuration Complete"
echo "============================================================"
echo ""
echo "  JWT auth path:    jwt-nomad"
echo "  JWKS URL:         http://${NOMAD_SERVER_IP}:${NOMAD_PORT}/.well-known/jwks.json"
echo "  JWT audience:     ${NOMAD_VAULT_JWT_AUD}"
echo "  Role:             nomad-workloads"
echo "  Policy:           nomad-workloads-wi"
echo ""
echo "  Nomad is still using LEGACY token auth at this point."
echo "  The legacy token continues to work — no downtime yet."
echo ""
echo "Next: scripts/11-migrate-consul-wi.sh"
echo "============================================================"
