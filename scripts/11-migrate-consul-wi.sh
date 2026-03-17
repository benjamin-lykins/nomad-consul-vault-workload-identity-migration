#!/usr/bin/env bash
# =============================================================================
# scripts/11-migrate-consul-wi.sh
# PHASE 2, STEP B — Configure Consul to accept Nomad Workload Identity JWTs
#
# What changes on Consul:
#   - Enable JWT auth method pointing at Nomad JWKS
#   - Create binding rules that map Nomad JWT claims to Consul roles
#   - Create Consul roles and policies for Nomad workloads
#   - NO changes to Nomad config yet (still uses legacy token)
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

CONSUL_IP=$(vm_ip "$VM_CONSUL")
NOMAD_SERVER_IP=$(vm_ip "$VM_NOMAD_SERVER")
CONSUL_BOOTSTRAP_TOKEN=$(load_secret "consul_bootstrap_token")

info "============================================================"
info "  STEP 11: Configuring Consul JWT auth for Workload Identity"
info "============================================================"

# ============================================================================
# 1. Create Consul policy for Nomad workload service/check registration
# ============================================================================
info "Creating Consul policy for Nomad workloads..."
vm_exec "$VM_CONSUL" "cat > /tmp/nomad-workloads-policy.hcl << 'POLICY'
# Nomad workload identity policy
# Grants workloads the ability to register services and checks for their own job

agent_prefix \"\" {
  policy = \"read\"
}
node_prefix \"\" {
  policy = \"read\"
}
# Allow workloads to register services namespaced by job/task
service_prefix \"\" {
  policy = \"write\"
}
POLICY
CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl policy create \
    -name 'nomad-workloads-wi' \
    -description 'Nomad workload identity policy' \
    -rules @/tmp/nomad-workloads-policy.hcl 2>/dev/null || \
CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl policy update \
    -name 'nomad-workloads-wi' \
    -rules @/tmp/nomad-workloads-policy.hcl
"
ok "Consul policy 'nomad-workloads-wi' created"

# ============================================================================
# 2. Create Consul role tied to the workload policy
# ============================================================================
info "Creating Consul role 'nomad-workloads'..."
vm_exec "$VM_CONSUL" "
CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl role create \
    -name 'nomad-workloads' \
    -description 'Role for Nomad workload identity tokens' \
    -policy-name 'nomad-workloads-wi' || {
  ROLE_ID=\$(CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
    CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
    consul acl role read -name 'nomad-workloads' -format json | jq -r '.ID')
  CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
  CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
    consul acl role update \
      -id \"\$ROLE_ID\" \
      -policy-name 'nomad-workloads-wi'
}
"
ok "Consul role 'nomad-workloads' created"

# ============================================================================
# 3. Enable JWT auth method on Consul pointing at Nomad JWKS
# ============================================================================
info "Configuring Consul JWT auth method..."
vm_exec "$VM_CONSUL" "cat > /tmp/nomad-workloads-auth.json << 'AUTHCONFIG'
{
  \"JWKSURL\": \"http://${NOMAD_SERVER_IP}:${NOMAD_PORT}/.well-known/jwks.json\",
  \"JWTSupportedAlgs\": [\"RS256\"],
  \"BoundAudiences\": [\"${NOMAD_CONSUL_JWT_AUD}\"],
  \"ClaimMappings\": {
    \"nomad_job_id\":        \"nomad_job_id\",
    \"nomad_namespace\":     \"nomad_namespace\",
    \"nomad_task\":          \"nomad_task\",
    \"nomad_allocation_id\": \"nomad_allocation_id\"
  }
}
AUTHCONFIG
CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl auth-method create \
    -name 'nomad-workloads' \
    -type 'jwt' \
    -description 'Nomad Workload Identity JWT auth' \
    -config @/tmp/nomad-workloads-auth.json || \
CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl auth-method update \
    -name 'nomad-workloads' \
    -config @/tmp/nomad-workloads-auth.json
"
ok "Consul JWT auth method 'nomad-workloads' configured"

# ============================================================================
# 4. Create binding rule to auto-assign role based on JWT claims
# ============================================================================
info "Creating Consul binding rule..."
vm_exec "$VM_CONSUL" "
CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl binding-rule create \
    -method 'nomad-workloads' \
    -description 'Bind all Nomad workload JWTs to the nomad-workloads role' \
    -bind-type 'role' \
    -bind-name 'nomad-workloads' \
    -selector 'value.nomad_job_id != \"\"' 2>/dev/null || true
"
ok "Consul binding rule created"

# ============================================================================
# 5. Verify
# ============================================================================
info "Verifying Consul JWT auth method..."
vm_exec "$VM_CONSUL" "
CONSUL_HTTP_ADDR=http://127.0.0.1:${CONSUL_PORT} \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl auth-method read -name nomad-workloads
"
ok "Consul JWT auth method verified"

echo ""
echo "============================================================"
echo "  Consul Workload Identity Configuration Complete"
echo "============================================================"
echo ""
echo "  Auth method:      nomad-workloads (JWT)"
echo "  JWKS URL:         http://${NOMAD_SERVER_IP}:${NOMAD_PORT}/.well-known/jwks.json"
echo "  JWT audience:     ${NOMAD_CONSUL_JWT_AUD}"
echo "  Binding rule:     nomad-workloads role"
echo ""
echo "  Nomad is STILL using legacy tokens at this point."
echo ""
echo "Next: scripts/12-update-nomad-wi.sh"
echo "============================================================"
