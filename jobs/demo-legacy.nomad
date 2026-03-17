// demo-legacy.nomad
// =============================================================================
// PHASE 1 — Legacy Vault + Consul token auth demo job
//
// Vault integration (legacy):
//   - Nomad server forwards a Vault token derived from the 'nomad-cluster' role
//   - The token is injected into the task via VAULT_TOKEN env var
//   - Task uses vault{} stanza to declare which secrets it needs
//
// Consul integration (legacy):
//   - Nomad client registers the service using the CONSUL_HTTP_TOKEN injected
//     via the systemd override created in 05-bootstrap.sh
//   - No workload identity — the token is shared across all Nomad workloads
//
// After migration this job will be replaced by demo-wi.nomad
// =============================================================================

job "demo-legacy" {
  datacenters = ["dc1"]
  type        = "service"
  namespace   = "default"

  group "reader" {
    count = 1

    # Legacy Vault integration — Nomad fetches a token via token role
    vault {
      policies      = ["nomad-workloads-legacy"]
      change_mode   = "restart"
      change_signal = "SIGTERM"
    }

    task "reader" {
      driver = "docker"

      config {
        image   = "alpine:3.19"
        command = "/bin/sh"
        args    = ["-c", "/local/run.sh"]
      }

      # Vault secret rendered via Nomad template (legacy approach)
      template {
        data        = <<-EOT
          #!/bin/sh
          # LEGACY auth: this secret was fetched using a Vault token
          # that Nomad obtained via the 'nomad-cluster' token role.
          AUTH_MODE="LEGACY_TOKEN"
          DB_PASSWORD="{{ with secret "secret/data/demo/config" }}{{ .Data.data.db_password }}{{ end }}"
          API_KEY="{{ with secret "secret/data/demo/config" }}{{ .Data.data.api_key }}{{ end }}"

          echo "======================================"
          echo "  Demo-Legacy: reading Vault secret"
          echo "======================================"
          echo "  Auth mode:    $AUTH_MODE"
          echo "  DB password:  $DB_PASSWORD"
          echo "  API key:      $API_KEY"
          echo "======================================"

          # Keep running so the job stays in the 'running' state
          while true; do
            echo "[$(date)] legacy auth heartbeat"
            sleep 30
          done
        EOT
        destination = "/local/run.sh"
        perms       = "755"
        change_mode = "restart"
      }

      # Legacy Consul service registration — Nomad registers this using the
      # shared CONSUL_HTTP_TOKEN from the systemd override (not per-workload).
      service {
        name     = "demo-legacy"
        port     = ""
        tags     = ["legacy", "demo"]
        provider = "consul"

        check {
          type     = "script"
          name     = "alive"
          command  = "/bin/sh"
          args     = ["-c", "exit 0"]
          interval = "30s"
          timeout  = "5s"
        }
      }

      resources {
        cpu    = 100
        memory = 64
      }

      # Legacy: Vault token injected by Nomad as VAULT_TOKEN
      # This env var is automatically set by the Nomad client for tasks
      # that declare a vault{} stanza.
    }
  }
}
