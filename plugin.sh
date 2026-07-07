#!/usr/bin/env bash
# =============================================================================
# proxmox — Woodpecker CI Plugin
# =============================================================================
# Manages Proxmox VE infrastructure: LXC containers, QEMU VMs, storage,
# networking, snapshots, backups, and more via the Proxmox REST API.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load libraries ──────────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/plugin-core.sh"
source "${SCRIPT_DIR}/lib/pve-api.sh"
source "${SCRIPT_DIR}/lib/pve-exec.sh"
source "${SCRIPT_DIR}/lib/pve-lxc.sh"
source "${SCRIPT_DIR}/lib/pve-vm.sh"
source "${SCRIPT_DIR}/lib/pve-node.sh"
source "${SCRIPT_DIR}/lib/pve-snapshot.sh"
source "${SCRIPT_DIR}/lib/pve-clone.sh"
source "${SCRIPT_DIR}/lib/pve-firewall.sh"
source "${SCRIPT_DIR}/lib/pve-access.sh"
source "${SCRIPT_DIR}/lib/pve-storage-mgmt.sh"
source "${SCRIPT_DIR}/lib/pve-pool.sh"
source "${SCRIPT_DIR}/lib/pve-ha.sh"
source "${SCRIPT_DIR}/lib/pve-disk.sh"
source "${SCRIPT_DIR}/lib/pve-cert.sh"
source "${SCRIPT_DIR}/lib/pve-task.sh"
source "${SCRIPT_DIR}/lib/pve-network-mgmt.sh"
source "${SCRIPT_DIR}/lib/pve-cloud-init.sh"
source "${SCRIPT_DIR}/lib/pve-replication.sh"
source "${SCRIPT_DIR}/lib/pve-ceph.sh"
source "${SCRIPT_DIR}/lib/pve-bulk.sh"
source "${SCRIPT_DIR}/lib/pve-console.sh"
source "${SCRIPT_DIR}/lib/pve-metrics.sh"
source "${SCRIPT_DIR}/lib/pve-workflow.sh"

# ── Plugin metadata ────────────────────────────────────────────────────
PLUGIN_NAME="proxmox"
PLUGIN_VERSION="4.0.0"

# ── Settings schema ────────────────────────────────────────────────────
settings_schema() {
  require_setting "ACTION"    "The action to perform"
  require_setting "API_URL"   "Proxmox API URL (e.g. https://pve.example.com:8006)"
  require_setting "API_TOKEN" "PVE API token (user@realm!tokenid=secret)"
  require_setting "NODE"      "Proxmox node name"

  optional_setting "AUTH_MODE"    "pve"
  optional_setting "SKIP_VERIFY"  "true"
  optional_setting "DEBUG"        "false"
  optional_setting "TIMEOUT"      "120"
  optional_setting "RETRY_MAX"    "3"
  optional_setting "RETRY_DELAY"  "2"
  optional_setting "HTTP_TIMEOUT" "30"
}

# ── Run ─────────────────────────────────────────────────────────────────
plugin_run "$@"
