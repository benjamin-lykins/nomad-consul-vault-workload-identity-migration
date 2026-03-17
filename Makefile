# =============================================================================
# Makefile — Nomad Workload Identity Migration Lab
# =============================================================================
SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

SCRIPTS := scripts

# Ensure scripts are executable before running
_ensure_exec:
	@chmod +x $(SCRIPTS)/*.sh $(SCRIPTS)/lib/*.sh

# =============================================================================
# PHASE 1 — Deploy infrastructure with LEGACY auth
# =============================================================================

## Create all Multipass VMs (vault-server, consul-server, nomad-server, nomad-client)
vms: _ensure_exec
	$(SCRIPTS)/00-create-vms.sh

## Install Vault on vault-server VM
vault: _ensure_exec
	$(SCRIPTS)/01-install-vault.sh

## Install Consul on consul-server VM
consul: _ensure_exec
	$(SCRIPTS)/02-install-consul.sh

## Install Nomad on nomad-server VM (legacy config)
nomad-server: _ensure_exec
	$(SCRIPTS)/03-install-nomad-server.sh

## Install Nomad on nomad-client VM (legacy config)
nomad-client: _ensure_exec
	$(SCRIPTS)/04-install-nomad-client.sh

## Bootstrap Vault (init+unseal), Consul ACLs, and Nomad with legacy tokens
bootstrap: _ensure_exec
	$(SCRIPTS)/05-bootstrap.sh

## Deploy legacy demo job and verify the "before" state
verify-legacy: _ensure_exec
	$(SCRIPTS)/06-verify-legacy.sh

## Run full Phase 1 deployment in order
deploy: _ensure_exec
	@echo "=== Phase 1: Full legacy deployment ==="
	$(SCRIPTS)/00-create-vms.sh
	$(SCRIPTS)/01-install-vault.sh
	$(SCRIPTS)/02-install-consul.sh
	$(SCRIPTS)/03-install-nomad-server.sh
	$(SCRIPTS)/04-install-nomad-client.sh
	$(SCRIPTS)/05-bootstrap.sh
	$(SCRIPTS)/06-verify-legacy.sh

# =============================================================================
# PHASE 2 — Migrate to Workload Identity
# =============================================================================

## Configure Vault JWT auth method for Nomad workload identity
migrate-vault: _ensure_exec
	$(SCRIPTS)/10-migrate-vault-wi.sh

## Configure Consul JWT auth method for Nomad workload identity
migrate-consul: _ensure_exec
	$(SCRIPTS)/11-migrate-consul-wi.sh

## Reconfigure Nomad server + client to use workload identity (replaces legacy tokens)
migrate-nomad: _ensure_exec
	$(SCRIPTS)/12-update-nomad-wi.sh

## Verify workload identity is working end-to-end
verify-wi: _ensure_exec
	$(SCRIPTS)/13-verify-migration.sh

## Run full Phase 2 migration in order
migrate: _ensure_exec
	@echo "=== Phase 2: Workload Identity Migration ==="
	$(SCRIPTS)/10-migrate-vault-wi.sh
	$(SCRIPTS)/11-migrate-consul-wi.sh
	$(SCRIPTS)/12-update-nomad-wi.sh
	$(SCRIPTS)/13-verify-migration.sh

# =============================================================================
# Utilities
# =============================================================================

## Show status of all Multipass VMs and service IPs
status:
	@source env.sh && \
	echo "" && \
	echo "============================================================" && \
	echo "  VM Status" && \
	echo "============================================================" && \
	multipass list && \
	echo "" && \
	echo "  Service endpoints:" && \
	for vm in vault-server consul-server nomad-server nomad-client; do \
	  ip=$$(multipass info $$vm 2>/dev/null | awk '/IPv4/ { print $$2; exit }'); \
	  printf "  %-20s  %s\n" "$$vm" "$${ip:-stopped}"; \
	done && \
	echo "============================================================"

## Open service UIs in the browser
ui:
	@source env.sh && \
	VAULT_IP=$$(multipass info vault-server 2>/dev/null | awk '/IPv4/ { print $$2; exit }') && \
	CONSUL_IP=$$(multipass info consul-server 2>/dev/null | awk '/IPv4/ { print $$2; exit }') && \
	NOMAD_IP=$$(multipass info nomad-server 2>/dev/null | awk '/IPv4/ { print $$2; exit }') && \
	open "http://$${VAULT_IP}:8200" && \
	open "http://$${CONSUL_IP}:8500" && \
	open "http://$${NOMAD_IP}:4646"

## Print saved secrets (for debugging)
secrets:
	@echo "Saved secrets in .secrets/:" && ls -la .secrets/ 2>/dev/null || echo "  (none yet)"

## Stop all VMs (preserves state)
stop:
	@source env.sh && \
	for vm in vault-server consul-server nomad-server nomad-client; do \
	  multipass stop $$vm 2>/dev/null && echo "Stopped $$vm" || true; \
	done

## Start all VMs
start:
	@source env.sh && \
	for vm in vault-server consul-server nomad-server nomad-client; do \
	  multipass start $$vm 2>/dev/null && echo "Started $$vm" || true; \
	done

## Unseal Vault after a VM restart
unseal:
	@source env.sh && \
	VAULT_IP=$$(multipass info vault-server | awk '/IPv4/ { print $$2; exit }') && \
	KEY=$$(cat .secrets/vault_unseal_key) && \
	multipass exec vault-server -- bash -c \
	  "VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal '$$KEY'" && \
	echo "Vault unsealed"

## Destroy ALL VMs and delete secrets (DESTRUCTIVE)
clean:
	@echo "WARNING: This will destroy all VMs and delete all secrets."
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ]
	@source env.sh && \
	for vm in vault-server consul-server nomad-server nomad-client; do \
	  multipass delete $$vm 2>/dev/null && echo "Deleted $$vm" || true; \
	done
	multipass purge
	rm -rf .secrets/
	@echo "All VMs and secrets removed."

## Shell into a VM: make shell VM=vault-server
shell:
	multipass shell $(VM)

## Show this help
help:
	@echo ""
	@echo "Nomad Workload Identity Migration Lab"
	@echo ""
	@echo "Usage: make <target>"
	@echo "Shortcuts:"
	@echo "  make deploy    — Full Phase 1 (VMs + install + bootstrap + verify)"
	@echo "  make migrate   — Full Phase 2 (configure WI + update Nomad + verify)"
	@echo "  make status    — Show VM IPs and service status"
	@echo "  make ui        — Open all service UIs in browser"
	@echo "  make clean     — Destroy everything"
	@echo ""

.PHONY: _ensure_exec vms vault consul nomad-server nomad-client bootstrap \
        verify-legacy deploy migrate-vault migrate-consul migrate-nomad \
        verify-wi migrate status ui secrets stop start unseal clean shell help
