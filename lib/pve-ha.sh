#!/usr/bin/env bash
# =============================================================================
# pve-ha.sh — High Availability management
# =============================================================================
# Actions: ha-group-list, ha-group-create, ha-resource-add, ha-status
# =============================================================================

[[ -n "${_PVE_HA_LOADED:-}" ]] && return 0
readonly _PVE_HA_LOADED=1

action_ha_group_list() {
  local result
  result=$(pve_get "/cluster/ha/groups")

  echo "$result" | jq -r '
    ["GROUP","NODES","RESTRICTED","NOFAILBACK","COMMENT"],
    (.data[] | [
      .group,
      (.nodes // "-"),
      (if .restricted == 1 then "yes" else "no" end),
      (if .nofailback == 1 then "yes" else "no" end),
      (.comment // "-" | .[0:30])
    ]) | @tsv' | column -t

  output_json "$(echo "$result" | jq '.data')"
  log_info "Found $(echo "$result" | jq '.data | length') HA group(s)"
}

action_ha_group_create() {
  require_setting "HA_GROUP" "HA group name"
  require_setting "HA_NODES" "Comma-separated node list (node:priority)"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local group="${PLUGIN_HA_GROUP}"
  local nodes="${PLUGIN_HA_NODES}"
  local restricted="${PLUGIN_RESTRICTED:-0}"
  local nofailback="${PLUGIN_NOFAILBACK:-0}"
  local comment="${PLUGIN_COMMENT:-}"

  # nodes is a "node:priority,node:priority" list — ':' and ',' need urlencoding.
  local args=(-d "group=${group}" --data-urlencode "nodes=${nodes}")
  args+=(-d "restricted=${restricted}" -d "nofailback=${nofailback}")
  [[ -n "$comment" ]] && args+=(--data-urlencode "comment=${comment}")

  pve_post "/cluster/ha/groups" "${args[@]}" >/dev/null
  log_info "HA group '${group}' created with nodes: ${nodes}"
}

action_ha_resource_add() {
  require_setting "VMID" "VM/container ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local vmid="${PLUGIN_VMID}"
  local group="${PLUGIN_HA_GROUP:-}"
  local max_restart="${PLUGIN_MAX_RESTART:-1}"
  local max_relocate="${PLUGIN_MAX_RELOCATE:-1}"
  local state="${PLUGIN_HA_STATE:-started}"
  local comment="${PLUGIN_COMMENT:-}"

  # Determine SID format (ct: or vm:)
  local gtype
  gtype=$(_guest_type_path) || exit $EXIT_API
  local sid
  [[ "$gtype" == "lxc" ]] && sid="ct:${vmid}" || sid="vm:${vmid}"

  local args=(-d "sid=${sid}" -d "state=${state}")
  args+=(-d "max_restart=${max_restart}" -d "max_relocate=${max_relocate}")
  [[ -n "$group" ]]   && args+=(-d "group=${group}")
  [[ -n "$comment" ]] && args+=(--data-urlencode "comment=${comment}")

  pve_post "/cluster/ha/resources" "${args[@]}" >/dev/null
  log_info "HA resource ${sid} added (state: ${state})"
}

action_ha_status() {
  local result
  result=$(pve_get "/cluster/ha/status/current")

  echo "$result" | jq '.data[] | {id, type, status, node, state, request_state, crm_state}'

  output_json "$(echo "$result" | jq '.data')"
  log_info "HA status retrieved"
}
