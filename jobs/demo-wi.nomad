// demo-wi.nomad
// =============================================================================
// PHASE 2 — Workload Identity Vault auth demo job
//
// Key differences from demo-legacy.nomad:
//
//   1. vault{} stanza: NO 'policies' field — the role is resolved via JWT claim
//      mapping configured in Vault (10-migrate-vault-wi.sh).
//
//   2. identity{} block: Nomad generates a short-lived JWT for this task,
//      bound to the audience "vault.io". This JWT is presented to Vault's
//      jwt-nomad auth method. No VAULT_TOKEN is injected by Nomad.
//
//   3. Same template{} syntax works — the secret path is unchanged.
//      Only the auth mechanism changed.
//
//   4. consul{} service block: Consul service registration uses the task's
//      own JWT (service_identity configured on the Nomad client) instead
//      of a shared Consul token.
// =============================================================================

job "demo-wi" {
  datacenters = ["dc1"]
  type        = "service"
  namespace   = "default"

  group "reader" {
    count = 1

    # Workload Identity for Vault access
    # Nomad will generate a JWT for this task and use jwt-nomad auth method.
    # No 'policies' needed here — the Vault JWT role resolves the policy.
    vault {
      # The 'role' here corresponds to the role created in Vault's jwt-nomad
      # auth method (see scripts/10-migrate-vault-wi.sh).
      # If omitted, the default role configured on the auth method is used.
      role = "nomad-workloads"
    }

    # Explicit workload identity block — overrides the server default if needed.
    # Audience must match bound_audiences in the Vault JWT role.
    identity {
      name = "vault_default"
      aud  = ["vault.io"]
      ttl  = "1h"
      # env = true  would expose NOMAD_TOKEN_vault_default — optional
      file = true   # written to NOMAD_SECRETS_DIR/vault_default.jwt
    }

    task "reader" {
      driver = "docker"

      config {
        image   = "alpine:3.19"
        command = "/bin/sh"
        args    = ["-c", "/local/run.sh"]
      }

      # Service registration via Consul Workload Identity
      # (no shared token — uses the task_identity JWT from the client config)
      service {
        name = "demo-wi-reader"
        port = ""    # no port — just showing catalog registration
        tags = ["workload-identity", "migrated"]

        check {
          type     = "script"
          command  = "/bin/sh"
          args     = ["-c", "exit 0"]
          interval = "30s"
          timeout  = "5s"
        }
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

          # Show the workload identity JWT file location
          echo "  JWT file:     \${NOMAD_SECRETS_DIR}/vault_default.jwt"
          if [ -f "\${NOMAD_SECRETS_DIR}/vault_default.jwt" ]; then
            echo "  JWT present:  YES (Nomad-generated, short-lived)"
            # Decode JWT header+payload (for demo — never log JWTs in production)
            JWT=\$(cat "\${NOMAD_SECRETS_DIR}/vault_default.jwt")
            PAYLOAD=\$(echo "\$JWT" | cut -d. -f2 | base64 -d 2>/dev/null || echo "decode failed")
            echo "  JWT payload:  \$PAYLOAD"
          else
            echo "  JWT present:  NO (check Nomad client config)"
          fi
          echo "=========================================="

          while true; do
            echo "[$(date)] workload identity heartbeat — no static tokens"
            sleep 30
          done
        EOT
        destination = "/local/run.sh"
        change_mode = "restart"
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
