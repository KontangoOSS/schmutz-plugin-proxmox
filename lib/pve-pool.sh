#!/usr/bin/env bash
# =============================================================================
# pve-pool.sh — Resource pool management
# =============================================================================
# Actions: pool-list, pool-create, pool-delete, pool-add-member
# =============================================================================

[[ -n "${_PVE_POOL_LOADED:-}" ]] && return 0
readonly _PVE_POOL_LOADED=1

action_pool_list() {
  local result
  result=$(pve_get "/pools")

  echo "$result" | jq -r '
    ["POOLID","COMMENT"],
    (.data[] | [
      .poolid,
      (.comment // "-" | .[0:50])
    ]) | @tsv' | column -t

  local count
  count=$(echo "$result" | jq '.data | length')
  output_var "POOL_COUNT" "$count"
  output_json "$(echo "$result" | jq '.data')"
  log_info "Found ${count} pool(s)"
}

action_pool_create() {
  require_setting "POOL_ID" "Pool identifier"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local poolid="${PLUGIN_POOL_ID}"
  local comment="${PLUGIN_COMMENT:-}"

  local args=(-d "poolid=${poolid}")
  [[ -n "$comment" ]] && args+=(--data-urlencode "comment=${comment}")

  pve_post "/pools" "${args[@]}" >/dev/null
  output_var "PROXMOX_POOL" "$poolid"
  log_info "Pool '${poolid}' created"
}

action_pool_delete() {
  require_setting "POOL_ID" "Pool identifier"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local poolid="${PLUGIN_POOL_ID}"
  pve_delete "/pools/${poolid}" >/dev/null
  log_info "Pool '${poolid}' deleted"
}

action_pool_add_member() {
  require_setting "POOL_ID" "Pool identifier"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local poolid="${PLUGIN_POOL_ID}"
  local vms="${PLUGIN_VMIDS:-}"
  local storage="${PLUGIN_STORAGE_IDS:-}"

  if [[ -z "$vms" && -z "$storage" ]]; then
    log_fatal "Specify vmids and/or storage_ids to add to pool"
  fi

  local args=()
  [[ -n "$vms" ]]     && args+=(-d "vms=${vms}")
  [[ -n "$storage" ]] && args+=(-d "storage=${storage}")

  pve_put "/pools/${poolid}" "${args[@]}" >/dev/null
  log_info "Members added to pool '${poolid}'"
}
