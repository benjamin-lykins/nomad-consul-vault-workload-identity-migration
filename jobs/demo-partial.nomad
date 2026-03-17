// demo-partial.nomad
// =============================================================================
// PHASE 2 — Partial migration window: Vault WI opted-in, Consul not yet cut over
//
// This job is valid AFTER steps 10+11 (Vault and Consul JWT auth configured)
// but BEFORE step 12 (Nomad client config switched).
//
// KEY DISTINCTION — migration granularity:
//
//   Vault (per-job, incremental):
//     Individual jobs opt-in to Vault WI by adding an identity{} block and
//     switching vault{ policies=[...] } to vault{ role="..." }. Jobs that
//     have NOT been updated continue using the legacy VAULT_TOKEN. Both can
//     run on the same cluster at the same time. This job has opted in.
//
//   Consul (per-client, full cutover):
//     Consul WI is configured in the Nomad CLIENT config via service_identity
//     and task_identity blocks — not in individual jobs. When the Nomad client
//     restarts with the new config (step 12), ALL services on that client switch
//     from the shared CONSUL_HTTP_TOKEN to per-workload JWTs simultaneously.
//     There is no per-job opt-in for Consul.
//
// What this means for this demo:
//   - "Vault = WI"     → this job explicitly opted in (identity block below)
//   - "Consul = legacy" → the Nomad client has NOT been switched yet (step 12
//                         has not run). Once step 12 runs, Consul flips for ALL
//                         jobs on this client regardless of what they declare.
//
// Run order: deploy this job BEFORE make migrate-nomad (step 12) to observe
// the coexistence window. After step 12, Consul WI is automatic for all jobs.
// =============================================================================

job "demo-partial" {
  datacenters = ["dc1"]
  type        = "service"
  namespace   = "default"

  group "reader" {
    count = 1

    # Vault: OPTED IN to Workload Identity (per-job choice).
    # The 'role' maps to the JWT role created in scripts/10-migrate-vault-wi.sh.
    # No 'policies' field — policy resolved via JWT claim mapping in Vault.
    # demo-legacy.nomad still uses vault{ policies=[...] } and that continues
    # to work because the Nomad server VAULT_TOKEN has not been removed yet.
    vault {
      role = "nomad-workloads"
    }

    # Vault identity JWT — presented to Vault's jwt-nomad auth method.
    # No static VAULT_TOKEN is injected into this task.
    identity {
      name = "vault_default"
      aud  = ["vault.io"]
      ttl  = "1h"
      file = true   # written to NOMAD_SECRETS_DIR/vault_default.jwt
    }

    # No consul identity block — and that is correct for this stage.
    # Consul WI is NOT a per-job opt-in. It is controlled by the Nomad client
    # config (service_identity / task_identity). Until step 12 runs, service
    # registration uses the shared CONSUL_HTTP_TOKEN for ALL jobs on this client,
    # including this one. After step 12, it switches automatically for all jobs.

    task "reader" {
      driver = "docker"

      config {
        image   = "alpine:3.19"
        command = "/bin/sh"
        args    = ["-c", "/local/run.sh"]
      }

      # Service registration — uses shared CONSUL_HTTP_TOKEN until step 12 runs,
      # then automatically switches to per-workload JWT (no job change required).
      service {
        name     = "demo-partial"
        tags     = ["partial-migration", "vault-wi", "pre-client-cutover"]
        provider = "consul"

        check {
          type = "ttl"
          name = "alive"
          ttl  = "60s"
        }
      }

      template {
        data        = <<-EOT
          #!/bin/sh
          # PARTIAL MIGRATION STATE (before step 12):
          #   Vault  — Workload Identity JWT  (this job opted in)
          #   Consul — shared CONSUL_HTTP_TOKEN (client not yet switched)
          #
          # After step 12 (make migrate-nomad):
          #   Consul flips to per-workload JWT for ALL jobs on this client.
          #   No change to this job file is required for Consul.
          AUTH_VAULT="WORKLOAD_IDENTITY_JWT"
          AUTH_CONSUL="LEGACY_TOKEN (client not yet switched — step 12 pending)"
          DB_PASSWORD="{{ with secret "secret/data/demo/config" }}{{ .Data.data.db_password }}{{ end }}"
          API_KEY="{{ with secret "secret/data/demo/config" }}{{ .Data.data.api_key }}{{ end }}"

          echo "=============================================="
          echo "  Demo-Partial: coexistence window"
          echo "=============================================="
          echo "  Vault auth:   $AUTH_VAULT"
          echo "  Consul auth:  $AUTH_CONSUL"
          echo "  DB password:  $DB_PASSWORD"
          echo "  API key:      $API_KEY"
          echo ""
          echo "--- Vault identity (opted in, WI active) ---"
          if [ -f "\${NOMAD_SECRETS_DIR}/vault_default.jwt" ]; then
            echo "  JWT present: YES (short-lived, audience: vault.io)"
            JWT=\$(cat "\${NOMAD_SECRETS_DIR}/vault_default.jwt")
            PAYLOAD=\$(echo "\$JWT" | cut -d. -f2 | base64 -d 2>/dev/null || echo "decode failed")
            echo "  Payload:     \$PAYLOAD"
          else
            echo "  JWT present: NO (check Nomad client config)"
          fi
          echo ""
          echo "--- Consul (client-level cutover, not yet triggered) ---"
          echo "  No per-job Consul JWT exists yet."
          echo "  Service registered via shared CONSUL_HTTP_TOKEN."
          echo "  Run 'make migrate-nomad' (step 12) to cut over all services"
          echo "  on this client to per-workload Consul JWTs simultaneously."
          echo "=============================================="

          while true; do
            echo "[$(date)] coexistence heartbeat — vault=WI consul=pre-cutover"
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
