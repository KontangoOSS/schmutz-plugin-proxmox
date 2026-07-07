#!/usr/bin/env bash
# =============================================================================
# pve-snapshot.sh — Snapshot and backup actions
# =============================================================================
# Actions: snapshot-create, snapshot-list, snapshot-rollback, snapshot-delete,
#          backup-create, backup-list
# =============================================================================

[[ -n "${_PVE_SNAPSHOT_LOADED:-}" ]] && return 0
readonly _PVE_SNAPSHOT_LOADED=1

# ── Helpers ─────────────────────────────────────────────────────────────

_guest_type_path() {
  # Detect whether VMID is an LXC or a QEMU guest and echo the path segment.
  # We list both guest types on the node (a list call failing is an
  # unambiguous hard error) and check membership — this distinguishes a real
  # "not found" from a transient API/auth error, which the previous
  # per-guest status probe could not (a 500 looked identical to a 404).
  local vmid="${PLUGIN_VMID}" node="${PLUGIN_NODE}"

  local lxc_list qemu_list
  if ! lxc_list=$(pve_get "/nodes/${node}/lxc"); then
    log_error "Failed to list LXC on node ${node} (API/auth error, not a missing guest)"
    return 1
  fi
  if echo "$lxc_list" | jq -e --arg v "$vmid" '.data[]? | select((.vmid|tostring) == $v)' >/dev/null 2>&1; then
    echo "lxc"; return 0
  fi

  if ! qemu_list=$(pve_get "/nodes/${node}/qemu"); then
    log_error "Failed to list QEMU on node ${node} (API/auth error, not a missing guest)"
    return 1
  fi
  if echo "$qemu_list" | jq -e --arg v "$vmid" '.data[]? | select((.vmid|tostring) == $v)' >/dev/null 2>&1; then
    echo "qemu"; return 0
  fi

  log_error "VMID ${vmid} not found as LXC or QEMU on node ${node}"
  return 1
}

# ── Snapshots ───────────────────────────────────────────────────────────

action_snapshot_create() {
  require_setting "VMID" "VM/container ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local snap_name="${PLUGIN_SNAPSHOT_NAME:-snap-$(date -u +%Y%m%d-%H%M%S)}"
  local description="${PLUGIN_DESCRIPTION:-Created by proxmox plugin}"

  local gtype
  gtype=$(_guest_type_path) || exit $EXIT_API

  log_info "Creating snapshot '${snap_name}' for ${gtype}/${vmid}"
  local args=(-d "snapname=${snap_name}" -d "description=${description}")
  [[ "${PLUGIN_INCLUDE_RAM:-false}" == "true" ]] && args+=(-d "vmstate=1")

  pve_post_task "/nodes/${node}/${gtype}/${vmid}/snapshot" "${args[@]}"

  output_var "SNAPSHOT_NAME" "$snap_name"
  log_info "Snapshot '${snap_name}' created"
}

action_snapshot_list() {
  require_setting "VMID" "VM/container ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local gtype
  gtype=$(_guest_type_path) || exit $EXIT_API

  local result
  result=$(pve_get "/nodes/${node}/${gtype}/${vmid}/snapshot")

  echo "$result" | jq -r '
    ["NAME","DESCRIPTION","PARENT","SNAPTIME"],
    (.data[] | select(.name != "current") | [
      .name,
      (.description // "-"),
      (.parent // "-"),
      (if .snaptime then (.snaptime | todate) else "-" end)
    ]) | @tsv' | column -t

  local count
  count=$(echo "$result" | jq '[.data[] | select(.name != "current")] | length')
  output_var "SNAPSHOT_COUNT" "$count"
  output_json "$(echo "$result" | jq '[.data[] | select(.name != "current")]')"
  log_info "Found ${count} snapshot(s)"
}

action_snapshot_rollback() {
  require_setting "VMID"          "VM/container ID"
  require_setting "SNAPSHOT_NAME" "Snapshot to rollback to"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local snap_name="${PLUGIN_SNAPSHOT_NAME}"
  local gtype
  gtype=$(_guest_type_path) || exit $EXIT_API

  log_info "Rolling back ${gtype}/${vmid} to snapshot '${snap_name}'"
  pve_post_task "/nodes/${node}/${gtype}/${vmid}/snapshot/${snap_name}/rollback"
  log_info "Rollback complete"
}

action_snapshot_delete() {
  require_setting "VMID"          "VM/container ID"
  require_setting "SNAPSHOT_NAME" "Snapshot to delete"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local snap_name="${PLUGIN_SNAPSHOT_NAME}"
  local gtype
  gtype=$(_guest_type_path) || exit $EXIT_API

  log_info "Deleting snapshot '${snap_name}' from ${gtype}/${vmid}"
  local result upid
  result=$(pve_delete "/nodes/${node}/${gtype}/${vmid}/snapshot/${snap_name}")
  upid=$(echo "$result" | jq -r '.data // empty')
  [[ -n "$upid" && "$upid" != "null" ]] && wait_for_task "$upid"
  log_info "Snapshot '${snap_name}' deleted"
}

# ── Backups ─────────────────────────────────────────────────────────────

action_backup_create() {
  require_setting "VMID" "VM/container ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local storage="${PLUGIN_BACKUP_STORAGE:-local}"
  local compress="${PLUGIN_COMPRESS:-zstd}"
  local mode="${PLUGIN_BACKUP_MODE:-snapshot}"

  log_info "Creating backup of VMID ${vmid} to ${storage} (${mode}, ${compress})"
  pve_post_task "/nodes/${node}/vzdump" \
    -d "vmid=${vmid}" \
    -d "storage=${storage}" \
    -d "compress=${compress}" \
    -d "mode=${mode}"

  log_info "Backup of VMID ${vmid} complete"
}

action_backup_list() {
  require_setting "VMID" "VM/container ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"

  # Scan all backup-capable storage
  local storages
  storages=$(pve_get "/nodes/${node}/storage" \
    | jq -r '.data[] | select(.content // "" | test("backup")) | .storage')

  local all_backups="[]"
  for storage in $storages; do
    local result
    result=$(pve_get "/nodes/${node}/storage/${storage}/content?content=backup&vmid=${vmid}" \
      2>/dev/null || echo '{"data":[]}')
    all_backups=$(echo "$all_backups" "$(echo "$result" | jq '.data')" \
      | jq -s 'add')
  done

  echo "$all_backups" | jq -r '
    ["VOLID","SIZE(GB)","FORMAT","CTIME"],
    (.[] | [
      .volid,
      ((.size // 0) / 1073741824 * 10 | floor / 10 | tostring),
      (.format // "-"),
      (if .ctime then (.ctime | todate) else "-" end)
    ]) | @tsv' | column -t

  local count
  count=$(echo "$all_backups" | jq 'length')
  output_var "BACKUP_COUNT" "$count"
  output_json "$all_backups"
  log_info "Found ${count} backup(s)"
}
