#!/usr/bin/env bash
# =============================================================================
# scripts/05-bootstrap.sh
# Bootstraps all services with LEGACY token-based authentication:
#
#   1. Initialize + unseal Vault
#   2. Bootstrap Consul ACLs → create Nomad server/client tokens
#   3. Create Vault policies + Nomad token role
#   4. Inject tokens into Nomad systemd overrides
#   5. Start Nomad server and client
#   6. Verify cluster health
#
# After this script, Nomad is running with the LEGACY auth model —
# ready to demonstrate the "before" state before workload identity migration.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

VAULT_IP=$(vm_ip "$VM_VAULT")
CONSUL_IP=$(vm_ip "$VM_CONSUL")
NOMAD_SERVER_IP=$(vm_ip "$VM_NOMAD_SERVER")
NOMAD_CLIENT_IP=$(vm_ip "$VM_NOMAD_CLIENT")

export VAULT_ADDR="https://${VAULT_IP}:${VAULT_PORT}"
export CONSUL_HTTP_ADDR="https://${CONSUL_IP}:${CONSUL_PORT}"

info "============================================================"
info "  Bootstrapping LEGACY auth — Vault + Consul + Nomad"
info "============================================================"

# ============================================================================
# STEP 1 — Vault: Initialize and Unseal
# ============================================================================
info "--- Step 1: Vault init & unseal ---"

# Check if already initialized
VAULT_INIT_STATUS=$(vm_exec "$VM_VAULT" \
  "VAULT_ADDR=https://127.0.0.1:${VAULT_PORT} VAULT_CACERT=/opt/tls/ca.crt vault status 2>/dev/null | awk '/^Initialized/{print \$2}'" || echo "false")

if [[ "$VAULT_INIT_STATUS" == "true" ]]; then
  warn "Vault already initialized — loading existing unseal key"
  VAULT_UNSEAL_KEY=$(load_secret "vault_unseal_key")
  VAULT_ROOT_TOKEN=$(load_secret "vault_root_token")
else
  info "Initializing Vault..."
  VAULT_INIT_OUTPUT=$(vm_exec "$VM_VAULT" \
    "VAULT_ADDR=https://127.0.0.1:${VAULT_PORT} VAULT_CACERT=/opt/tls/ca.crt vault operator init \
      -key-shares=1 -key-threshold=1 -format=json")

  VAULT_UNSEAL_KEY=$(echo "$VAULT_INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
  VAULT_ROOT_TOKEN=$(echo "$VAULT_INIT_OUTPUT" | jq -r '.root_token')

  save_secret "vault_unseal_key"  "$VAULT_UNSEAL_KEY"
  save_secret "vault_root_token"  "$VAULT_ROOT_TOKEN"
  ok "Vault initialized — keys saved to ${SECRETS_DIR}/"
fi

info "Unsealing Vault..."
vm_exec "$VM_VAULT" \
  "VAULT_ADDR=https://127.0.0.1:${VAULT_PORT} VAULT_CACERT=/opt/tls/ca.crt vault operator unseal '${VAULT_UNSEAL_KEY}'"
ok "Vault unsealed"

# Wait for Vault to become active
for i in $(seq 1 20); do
  STATUS=$(vm_exec "$VM_VAULT" \
    "VAULT_ADDR=https://127.0.0.1:${VAULT_PORT} VAULT_CACERT=/opt/tls/ca.crt vault status 2>/dev/null | awk '/^Sealed/{print \$2}'" || echo "true")
  [[ "$STATUS" == "false" ]] && break
  sleep 2
done
[[ "$STATUS" == "false" ]] || die "Vault did not unseal in time"
ok "Vault is active and unsealed"

# ============================================================================
# STEP 2 — Consul: Bootstrap ACLs
# ============================================================================
info "--- Step 2: Consul ACL bootstrap ---"

if [[ -f "${SECRETS_DIR}/consul_bootstrap_token" ]]; then
  warn "Consul ACLs already bootstrapped — loading token"
  CONSUL_BOOTSTRAP_TOKEN=$(load_secret "consul_bootstrap_token")
else
  info "Bootstrapping Consul ACLs..."
  CONSUL_BOOTSTRAP_OUTPUT=$(vm_exec "$VM_CONSUL" \
    "CONSUL_HTTP_ADDR=https://127.0.0.1:${CONSUL_PORT} CONSUL_CACERT=/opt/tls/ca.crt consul acl bootstrap -format=json")
  CONSUL_BOOTSTRAP_TOKEN=$(echo "$CONSUL_BOOTSTRAP_OUTPUT" | jq -r '.SecretID')
  save_secret "consul_bootstrap_token" "$CONSUL_BOOTSTRAP_TOKEN"
  ok "Consul ACLs bootstrapped"
fi

export CONSUL_HTTP_TOKEN="$CONSUL_BOOTSTRAP_TOKEN"

# ---------------------------------------------------------------------------
# Create Consul policies for Nomad server and client
# ---------------------------------------------------------------------------
info "Creating Consul policies for Nomad..."

# Nomad server policy
vm_exec "$VM_CONSUL" "cat > /tmp/nomad-server-policy.hcl << 'POLICY'
# Allow Nomad server to register services and manage health checks
agent_prefix \"\" {
  policy = \"read\"
}
node_prefix \"\" {
  policy = \"read\"
}
service_prefix \"\" {
  policy = \"write\"
}
acl = \"write\"
POLICY
CONSUL_HTTP_ADDR=https://127.0.0.1:${CONSUL_PORT} \
CONSUL_CACERT=/opt/tls/ca.crt \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl policy create \
    -name nomad-server \
    -description 'Nomad server legacy token policy' \
    -rules @/tmp/nomad-server-policy.hcl 2>/dev/null || \
CONSUL_HTTP_ADDR=https://127.0.0.1:${CONSUL_PORT} \
CONSUL_CACERT=/opt/tls/ca.crt \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl policy update \
    -name nomad-server \
    -rules @/tmp/nomad-server-policy.hcl"

# Nomad server token
CONSUL_NOMAD_SERVER_TOKEN=$(vm_exec "$VM_CONSUL" \
  "CONSUL_HTTP_ADDR=https://127.0.0.1:${CONSUL_PORT} \
CONSUL_CACERT=/opt/tls/ca.crt \
  CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl token create \
    -description 'Nomad server legacy token' \
    -policy-name nomad-server \
    -format=json" | jq -r '.SecretID')
save_secret "consul_nomad_server_token" "$CONSUL_NOMAD_SERVER_TOKEN"
ok "Consul Nomad-server token created"

# Nomad client policy
vm_exec "$VM_CONSUL" "cat > /tmp/nomad-client-policy.hcl << 'POLICY'
agent_prefix \"\" {
  policy = \"read\"
}
node_prefix \"\" {
  policy = \"read\"
}
service_prefix \"\" {
  policy = \"write\"
}
POLICY
CONSUL_HTTP_ADDR=https://127.0.0.1:${CONSUL_PORT} \
CONSUL_CACERT=/opt/tls/ca.crt \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl policy create \
    -name nomad-client \
    -description 'Nomad client legacy token policy' \
    -rules @/tmp/nomad-client-policy.hcl 2>/dev/null || \
CONSUL_HTTP_ADDR=https://127.0.0.1:${CONSUL_PORT} \
CONSUL_CACERT=/opt/tls/ca.crt \
CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl policy update \
    -name nomad-client \
    -rules @/tmp/nomad-client-policy.hcl"

CONSUL_NOMAD_CLIENT_TOKEN=$(vm_exec "$VM_CONSUL" \
  "CONSUL_HTTP_ADDR=https://127.0.0.1:${CONSUL_PORT} \
CONSUL_CACERT=/opt/tls/ca.crt \
  CONSUL_HTTP_TOKEN=${CONSUL_BOOTSTRAP_TOKEN} \
  consul acl token create \
    -description 'Nomad client legacy token' \
    -policy-name nomad-client \
    -format=json" | jq -r '.SecretID')
save_secret "consul_nomad_client_token" "$CONSUL_NOMAD_CLIENT_TOKEN"
ok "Consul Nomad-client token created"

# ============================================================================
# STEP 3 — Vault: Create Nomad token policy and legacy token role
# ============================================================================
info "--- Step 3: Vault — Nomad legacy token setup ---"

# Enable KV secrets engine for demo data
vm_exec "$VM_VAULT" "
VAULT_ADDR=https://127.0.0.1:${VAULT_PORT} \
VAULT_CACERT=/opt/tls/ca.crt \
VAULT_TOKEN=${VAULT_ROOT_TOKEN} \
  vault secrets enable -path=secret kv-v2 2>/dev/null || true

# Write a demo secret for the legacy job
VAULT_ADDR=https://127.0.0.1:${VAULT_PORT} \
VAULT_CACERT=/opt/tls/ca.crt \
VAULT_TOKEN=${VAULT_ROOT_TOKEN} \
  vault kv put secret/demo/config \
    db_password='super-secret-legacy' \
    api_key='legacy-api-key-12345'
"
ok "KV secrets engine enabled, demo secret written"

# Create a Vault policy that Nomad workloads can use (legacy)
vm_exec "$VM_VAULT" "cat > /tmp/nomad-workloads-legacy-policy.hcl << 'POLICY'
# Allow Nomad workloads (via legacy token role) to read demo secrets
path \"secret/data/demo/*\" {
  capabilities = [\"read\"]
}
path \"secret/metadata/demo/*\" {
  capabilities = [\"list\", \"read\"]
}
POLICY
VAULT_ADDR=https://127.0.0.1:${VAULT_PORT} \
VAULT_CACERT=/opt/tls/ca.crt \
VAULT_TOKEN=${VAULT_ROOT_TOKEN} \
  vault policy write nomad-workloads-legacy /tmp/nomad-workloads-legacy-policy.hcl"
ok "Vault policy 'nomad-workloads-legacy' created"

# Create Vault token role for Nomad legacy integration
vm_exec "$VM_VAULT" "
VAULT_ADDR=https://127.0.0.1:${VAULT_PORT} \
VAULT_CACERT=/opt/tls/ca.crt \
VAULT_TOKEN=${VAULT_ROOT_TOKEN} \
  vault write auth/token/roles/nomad-cluster \
    disallowed_policies=root \
    explicit_max_ttl=0 \
    name=nomad-cluster \
    orphan=false \
    period=259200 \
    renewable=true \
    allowed_policies='nomad-workloads-legacy'
"
ok "Vault token role 'nomad-cluster' created"

# Create a policy allowing Nomad server to manage tokens
vm_exec "$VM_VAULT" "cat > /tmp/nomad-server-vault-policy.hcl << 'POLICY'
# Nomad server needs to create/revoke tokens for workloads
path \"auth/token/create/nomad-cluster\" {
  capabilities = [\"update\"]
}
path \"auth/token/roles/nomad-cluster\" {
  capabilities = [\"read\"]
}
path \"auth/token/lookup-self\" {
  capabilities = [\"read\"]
}
path \"auth/token/lookup\" {
  capabilities = [\"update\"]
}
path \"auth/token/revoke-accessor\" {
  capabilities = [\"update\"]
}
path \"sys/capabilities-self\" {
  capabilities = [\"update\"]
}
path \"auth/token/renew-self\" {
  capabilities = [\"update\"]
}
POLICY
VAULT_ADDR=https://127.0.0.1:${VAULT_PORT} \
VAULT_CACERT=/opt/tls/ca.crt \
VAULT_TOKEN=${VAULT_ROOT_TOKEN} \
  vault policy write nomad-server /tmp/nomad-server-vault-policy.hcl"

# Create the Nomad server Vault token
VAULT_NOMAD_SERVER_TOKEN=$(vm_exec "$VM_VAULT" "
VAULT_ADDR=https://127.0.0.1:${VAULT_PORT} \
VAULT_CACERT=/opt/tls/ca.crt \
VAULT_TOKEN=${VAULT_ROOT_TOKEN} \
  vault token create \
    -policy=nomad-server \
    -period=72h \
    -orphan \
    -format=json" | jq -r '.auth.client_token')
save_secret "vault_nomad_server_token" "$VAULT_NOMAD_SERVER_TOKEN"
ok "Vault Nomad-server token created"

# ============================================================================
# STEP 4 — Inject tokens into Nomad server systemd override
# ============================================================================
info "--- Step 4: Inject tokens into Nomad server systemd override ---"

CONSUL_NOMAD_SERVER_TOKEN=$(load_secret "consul_nomad_server_token")
VAULT_NOMAD_SERVER_TOKEN=$(load_secret "vault_nomad_server_token")

vm_exec "$VM_NOMAD_SERVER" "
sudo mkdir -p /etc/systemd/system/nomad.service.d
printf '[Service]\n# LEGACY auth tokens — to be removed during workload identity migration\nEnvironment='"'"'VAULT_TOKEN=${VAULT_NOMAD_SERVER_TOKEN}'"'"'\nEnvironment='"'"'CONSUL_HTTP_TOKEN=${CONSUL_NOMAD_SERVER_TOKEN}'"'"'\n' \
  | sudo tee /etc/systemd/system/nomad.service.d/tokens.conf > /dev/null
sudo systemctl daemon-reload
sudo systemctl restart nomad
"
wait_for_port "$VM_NOMAD_SERVER" "$NOMAD_PORT" "Nomad server"
ok "Nomad server started with legacy tokens"

# ============================================================================
# STEP 5 — Inject tokens into Nomad client systemd override
# ============================================================================
info "--- Step 5: Inject tokens into Nomad client systemd override ---"

CONSUL_NOMAD_CLIENT_TOKEN=$(load_secret "consul_nomad_client_token")

vm_exec "$VM_NOMAD_CLIENT" "
sudo mkdir -p /etc/systemd/system/nomad.service.d
printf '[Service]\n# LEGACY auth tokens\nEnvironment='"'"'VAULT_TOKEN=${VAULT_NOMAD_SERVER_TOKEN}'"'"'\nEnvironment='"'"'CONSUL_HTTP_TOKEN=${CONSUL_NOMAD_CLIENT_TOKEN}'"'"'\n' \
  | sudo tee /etc/systemd/system/nomad.service.d/tokens.conf > /dev/null
sudo systemctl daemon-reload
sudo systemctl restart nomad
"
wait_for_port "$VM_NOMAD_CLIENT" "$NOMAD_PORT" "Nomad client"
ok "Nomad client started with legacy tokens"

# ============================================================================
# STEP 6 — Verify cluster health
# ============================================================================
info "--- Step 6: Verify cluster health ---"
sleep 5  # give cluster time to elect a leader

NOMAD_SERVER_STATUS=$(vm_exec "$VM_NOMAD_SERVER" \
  "NOMAD_ADDR=https://127.0.0.1:${NOMAD_PORT} NOMAD_CACERT=/opt/tls/ca.crt nomad server members 2>/dev/null" || echo "error")

if echo "$NOMAD_SERVER_STATUS" | grep -q "alive"; then
  ok "Nomad cluster is healthy"
else
  warn "Nomad cluster may not be fully ready yet — check with: make status"
fi

NODE_STATUS=$(vm_exec "$VM_NOMAD_SERVER" \
  "NOMAD_ADDR=https://127.0.0.1:${NOMAD_PORT} NOMAD_CACERT=/opt/tls/ca.crt nomad node status 2>/dev/null" || echo "")
if echo "$NODE_STATUS" | grep -q "ready"; then
  ok "Nomad client node is ready"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "============================================================"
echo "  LEGACY Bootstrap Complete"
echo "============================================================"
echo "  Vault UI:    https://${VAULT_IP}:${VAULT_PORT}"
echo "  Consul UI:   https://${CONSUL_IP}:${CONSUL_PORT}"
echo "  Nomad UI:    https://${NOMAD_SERVER_IP}:${NOMAD_PORT}"
echo ""
echo "  Vault root token:  $(load_secret vault_root_token)"
echo ""
echo "  Secrets saved to:  ${SECRETS_DIR}/"
echo "============================================================"
echo ""
echo "Next: run scripts/06-verify-legacy.sh to confirm the legacy"
echo "      setup is working, then begin migration."
