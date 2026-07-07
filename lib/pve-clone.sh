#!/usr/bin/env bash
# =============================================================================
# pve-clone.sh — Clone and migrate actions
# =============================================================================
# Actions: clone, migrate
# =============================================================================

[[ -n "${_PVE_CLONE_LOADED:-}" ]] && return 0
readonly _PVE_CLONE_LOADED=1

action_clone() {
  require_setting "VMID" "Source VM/container ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local newid="${PLUGIN_NEWID:-}"
  local name="${PLUGIN_CLONE_NAME:-}"
  local target_node="${PLUGIN_TARGET_NODE:-}"
  local storage="${PLUGIN_STORAGE:-}"
  local full="${PLUGIN_FULL_CLONE:-true}"
  local pool="${PLUGIN_POOL:-}"
  local description="${PLUGIN_DESCRIPTION:-}"

  # Auto-assign VMID if not specified
  if [[ -z "$newid" ]]; then
    newid=$(find_next_vmid) || log_fatal "Failed to get next VMID"
    log_info "Auto-assigned VMID: ${newid}"
  fi

  local gtype
  gtype=$(_guest_type_path) || exit $EXIT_API

  log_info "Cloning ${gtype}/${vmid} -> ${newid}"

  local args=(-d "newid=${newid}")
  [[ -n "$name" ]]        && args+=(-d "name=${name}")
  [[ -n "$target_node" ]] && args+=(-d "target=${target_node}")
  [[ -n "$storage" ]]     && args+=(-d "storage=${storage}")
  [[ -n "$pool" ]]        && args+=(-d "pool=${pool}")
  [[ -n "$description" ]] && args+=(--data-urlencode "description=${description}")
  [[ "$full" == "true" ]] && args+=(-d "full=1")

  pve_post_task "/nodes/${node}/${gtype}/${vmid}/clone" "${args[@]}"

  output_var "PROXMOX_VMID" "$newid"
  output_var "PROXMOX_SOURCE_VMID" "$vmid"
  log_info "Clone complete: ${vmid} -> ${newid}"
}

action_migrate() {
  require_setting "VMID"        "VM/container ID"
  require_setting "TARGET_NODE" "Destination node"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local target="${PLUGIN_TARGET_NODE}"
  local online="${PLUGIN_ONLINE:-false}"
  local storage="${PLUGIN_TARGET_STORAGE:-}"

  local gtype
  gtype=$(_guest_type_path) || exit $EXIT_API

  log_info "Migrating ${gtype}/${vmid} from ${node} to ${target}"

  local args=(-d "target=${target}")
  [[ "$online" == "true" ]] && args+=(-d "online=1")
  [[ -n "$storage" ]]       && args+=(-d "targetstorage=${storage}")

  pve_post_task "/nodes/${node}/${gtype}/${vmid}/migrate" "${args[@]}"

  output_var "PROXMOX_NODE" "$target"
  log_info "Migration complete: ${vmid} -> ${target}"
}
