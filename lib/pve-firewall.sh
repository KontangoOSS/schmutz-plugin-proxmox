#!/usr/bin/env bash
# =============================================================================
# pve-firewall.sh — Firewall management actions
# =============================================================================
# Actions: firewall-rules, firewall-add, firewall-delete, firewall-options
# =============================================================================

[[ -n "${_PVE_FIREWALL_LOADED:-}" ]] && return 0
readonly _PVE_FIREWALL_LOADED=1

# Determine the firewall API base path
_fw_base() {
  local vmid="${PLUGIN_VMID:-}"
  local scope="${PLUGIN_FW_SCOPE:-guest}"

  if [[ "$scope" == "cluster" ]]; then
    echo "/cluster/firewall"
  elif [[ "$scope" == "node" ]]; then
    echo "/nodes/${PLUGIN_NODE}/firewall"
  elif [[ -n "$vmid" ]]; then
    local gtype
    gtype=$(_guest_type_path) || return 1
    echo "/nodes/${PLUGIN_NODE}/${gtype}/${vmid}/firewall"
  else
    echo "/cluster/firewall"
  fi
}

action_firewall_rules() {
  local base
  base=$(_fw_base) || exit $EXIT_API

  local result
  result=$(pve_get "${base}/rules")

  echo "$result" | jq -r '
    ["POS","TYPE","ACTION","PROTO","DPORT","SOURCE","DEST","ENABLE","COMMENT"],
    (.data[] | [
      .pos,
      (.type // "-"),
      (.action // "-"),
      (.proto // "any"),
      (.dport // "-"),
      (.source // "any"),
      (.dest // "any"),
      (if .enable == 1 then "yes" else "no" end),
      (.comment // "-")
    ]) | @tsv' | column -t

  local count
  count=$(echo "$result" | jq '.data | length')
  output_var "RULE_COUNT" "$count"
  output_json "$(echo "$result" | jq '.data')"
  log_info "Found ${count} firewall rule(s)"
}

action_firewall_add() {
  require_setting "FW_ACTION" "Firewall action (ACCEPT, DROP, REJECT)"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local base
  base=$(_fw_base) || exit $EXIT_API

  local fw_action="${PLUGIN_FW_ACTION}"
  local fw_type="${PLUGIN_FW_TYPE:-in}"
  local proto="${PLUGIN_PROTO:-tcp}"
  local dport="${PLUGIN_DPORT:-}"
  local source="${PLUGIN_SOURCE:-}"
  local dest="${PLUGIN_DEST:-}"
  local comment="${PLUGIN_COMMENT:-}"
  local enable="${PLUGIN_ENABLE:-1}"

  # dport (ranges like 8000:8100), source/dest (CIDR lists like 10.0.0.0/8,192...)
  # contain ':' '/' ',' — must be urlencoded or -d corrupts them into a 400.
  local args=(-d "action=${fw_action}" -d "type=${fw_type}")
  [[ -n "$proto" ]]   && args+=(-d "proto=${proto}")
  [[ -n "$dport" ]]   && args+=(--data-urlencode "dport=${dport}")
  [[ -n "$source" ]]  && args+=(--data-urlencode "source=${source}")
  [[ -n "$dest" ]]    && args+=(--data-urlencode "dest=${dest}")
  [[ -n "$comment" ]] && args+=(--data-urlencode "comment=${comment}")
  args+=(-d "enable=${enable}")

  pve_post "${base}/rules" "${args[@]}" >/dev/null
  log_info "Firewall rule added: ${fw_type} ${fw_action} ${proto}${dport:+:${dport}}"
}

action_firewall_delete() {
  require_setting "FW_POS" "Rule position number"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local base
  base=$(_fw_base) || exit $EXIT_API

  local pos="${PLUGIN_FW_POS}"
  pve_delete "${base}/rules/${pos}" >/dev/null
  log_info "Firewall rule at position ${pos} deleted"
}

action_firewall_options() {
  local base
  base=$(_fw_base) || exit $EXIT_API

  local result
  result=$(pve_get "${base}/options")
  echo "$result" | jq '.data'
  output_json "$(echo "$result" | jq '.data')"
}
