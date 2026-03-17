// demo-wi.nomad
// =============================================================================
// PHASE 2 — Workload Identity Vault + Consul auth demo job
//
// Key differences from demo-legacy.nomad:
//
//   1. vault{} stanza: NO 'policies' field — the role is resolved via JWT claim
//      mapping configured in Vault (10-migrate-vault-wi.sh).
//
//   2. identity "vault_default": Nomad generates a short-lived JWT for this
//      task bound to audience "vault.io". Presented to Vault's JWT auth method.
//      No static VAULT_TOKEN is ever injected.
//
//   3. identity "consul_default": A separate short-lived JWT bound to audience
//      "consul.io". The Nomad client presents this to Consul's JWT auth method
//      when registering the service — no shared CONSUL_HTTP_TOKEN needed.
//
//   4. Same template{} syntax — only the auth mechanism changed.
// =============================================================================

job "demo-wi" {
  datacenters = ["dc1"]
  type        = "service"
  namespace   = "default"

  group "reader" {
    count = 1

    task "reader" {
      driver = "docker"

      # Workload Identity for Vault — audience must match bound_audiences in the
      # Vault JWT role (see scripts/10-migrate-vault-wi.sh).
      vault {
        role = "nomad-workloads"
      }

      # Additional identity for Vault JWT auth
      identity {
        name = "vault_default"
        aud  = ["vault.io"]
        ttl  = "1h"
        file = true   # written to NOMAD_SECRETS_DIR/vault_default.jwt
      }

      # Additional identity for Consul JWT auth (see scripts/11-migrate-consul-wi.sh)
      identity {
        name = "consul_default"
        aud  = ["consul.io"]
        ttl  = "1h"
        file = true   # written to NOMAD_SECRETS_DIR/consul_default.jwt
      }

      config {
        image   = "alpine:3.19"
        command = "/bin/sh"
        args    = ["-c", "/local/run.sh"]
      }

      # Service registration via Consul Workload Identity
      # Nomad presents the consul_default JWT to Consul's JWT auth method —
      # no shared CONSUL_HTTP_TOKEN, each allocation gets its own identity.
      service {
        name     = "demo-wi-reader"
        tags     = ["workload-identity", "migrated"]
        provider = "consul"

      }

      # Same template syntax as the legacy job — only auth mechanism changed
      template {
        data        = <<-EOT
          #!/bin/sh
          # WORKLOAD IDENTITY auth:
          #   - Nomad generated a JWT for this allocation
          #   - Vault's jwt-nomad auth method validated the JWT
          #   - No VAULT_TOKEN was ever injected — zero static secrets!
          AUTH_MODE="WORKLOAD_IDENTITY_JWT"
          DB_PASSWORD="{{ with secret "secret/data/demo/config" }}{{ .Data.data.db_password }}{{ end }}"
          API_KEY="{{ with secret "secret/data/demo/config" }}{{ .Data.data.api_key }}{{ end }}"

          echo "=========================================="
          echo "  Demo-WI: reading Vault secret via JWT"
          echo "=========================================="
          echo "  Auth mode:    $AUTH_MODE"
          echo "  DB password:  $DB_PASSWORD"
          echo "  API key:      $API_KEY"
          echo ""

          echo ""
          echo "--- Vault identity ---"
          echo "  JWT file:  \${NOMAD_SECRETS_DIR}/vault_default.jwt"
          if [ -f "\${NOMAD_SECRETS_DIR}/vault_default.jwt" ]; then
            echo "  Present:   YES (short-lived, audience: vault.io)"
            JWT=\$(cat "\${NOMAD_SECRETS_DIR}/vault_default.jwt")
            PAYLOAD=\$(echo "\$JWT" | cut -d. -f2 | base64 -d 2>/dev/null || echo "decode failed")
            echo "  Payload:   \$PAYLOAD"
          else
            echo "  Present:   NO (check Nomad client config)"
          fi

          echo ""
          echo "--- Consul identity ---"
          echo "  JWT file:  \${NOMAD_SECRETS_DIR}/consul_default.jwt"
          if [ -f "\${NOMAD_SECRETS_DIR}/consul_default.jwt" ]; then
            echo "  Present:   YES (short-lived, audience: consul.io)"
            JWT=\$(cat "\${NOMAD_SECRETS_DIR}/consul_default.jwt")
            PAYLOAD=\$(echo "\$JWT" | cut -d. -f2 | base64 -d 2>/dev/null || echo "decode failed")
            echo "  Payload:   \$PAYLOAD"
          else
            echo "  Present:   NO (check Nomad client config)"
          fi
          echo "=========================================="

          while true; do
            echo "[$(date)] workload identity heartbeat — no static tokens"
            sleep 30
          done
        EOT
        destination = "/local/run.sh"
        perms       = "755"
        change_mode = "restart"
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
