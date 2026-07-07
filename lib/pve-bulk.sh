#!/usr/bin/env bash
# =============================================================================
# pve-bulk.sh — Bulk operations on multiple VMs/containers
# =============================================================================
# Actions: bulk-start, bulk-stop, bulk-snapshot, bulk-backup
# =============================================================================

[[ -n "${_PVE_BULK_LOADED:-}" ]] && return 0
readonly _PVE_BULK_LOADED=1

# Run a function for each VMID in PLUGIN_VMIDS (comma-separated)
_bulk_run() {
  local action_desc="$1" fn="$2"
  require_setting "VMIDS" "Comma-separated list of VMIDs"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local vmids="${PLUGIN_VMIDS}"
  local ok=0 fail=0

  IFS=',' read -ra ids <<< "$vmids"
  log_info "${action_desc} for ${#ids[@]} guest(s): ${vmids}"

  for vmid in "${ids[@]}"; do
    vmid=$(echo "$vmid" | tr -d ' ')
    export PLUGIN_VMID="$vmid"
    if "$fn" "$vmid"; then
      ok=$((ok + 1))
    else
      log_error "Failed for VMID ${vmid}"
      fail=$((fail + 1))
    fi
  done

  log_info "Bulk ${action_desc}: ${ok} ok, ${fail} failed"
  output_var "BULK_OK" "$ok"
  output_var "BULK_FAIL" "$fail"
  [[ $fail -gt 0 ]] && return 1
  return 0
}

_bulk_start_one() {
  local vmid="$1" node="${PLUGIN_NODE}"
  local gtype
  gtype=$(_guest_type_path) || return 1
  log_info "Starting ${gtype}/${vmid}"
  pve_post_task "/nodes/${node}/${gtype}/${vmid}/status/start"
}

_bulk_stop_one() {
  local vmid="$1" node="${PLUGIN_NODE}"
  local gtype
  gtype=$(_guest_type_path) || return 1
  log_info "Stopping ${gtype}/${vmid}"
  pve_post_task "/nodes/${node}/${gtype}/${vmid}/status/stop"
}

_bulk_snapshot_one() {
  local vmid="$1" node="${PLUGIN_NODE}"
  local snap_name="${PLUGIN_SNAPSHOT_NAME:-bulk-snap-$(date -u +%Y%m%d-%H%M%S)}"
  local gtype
  gtype=$(_guest_type_path) || return 1
  log_info "Snapshot ${gtype}/${vmid}: ${snap_name}"
  pve_post_task "/nodes/${node}/${gtype}/${vmid}/snapshot" \
    -d "snapname=${snap_name}" -d "description=Bulk snapshot"
}

_bulk_backup_one() {
  local vmid="$1" node="${PLUGIN_NODE}"
  local storage="${PLUGIN_BACKUP_STORAGE:-local}"
  local compress="${PLUGIN_COMPRESS:-zstd}"
  log_info "Backup VMID ${vmid}"
  pve_post_task "/nodes/${node}/vzdump" \
    -d "vmid=${vmid}" -d "storage=${storage}" -d "compress=${compress}" -d "mode=snapshot"
}

action_bulk_start()    { _bulk_run "start"    _bulk_start_one; }
action_bulk_stop()     { _bulk_run "stop"     _bulk_stop_one; }
action_bulk_snapshot() { _bulk_run "snapshot" _bulk_snapshot_one; }
action_bulk_backup()   { _bulk_run "backup"   _bulk_backup_one; }
