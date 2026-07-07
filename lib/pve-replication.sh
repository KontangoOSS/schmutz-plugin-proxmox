#!/usr/bin/env bash
# =============================================================================
# pve-replication.sh — Storage replication management
# =============================================================================
# Actions: replication-list, replication-create, replication-status
# =============================================================================

[[ -n "${_PVE_REPLICATION_LOADED:-}" ]] && return 0
readonly _PVE_REPLICATION_LOADED=1

action_replication_list() {
  local result
  result=$(pve_get "/cluster/replication")

  echo "$result" | jq -r '
    ["ID","TYPE","SOURCE","TARGET","GUEST","SCHEDULE","COMMENT"],
    (.data[] | [
      .id,
      (.type // "-"),
      (.source // "-"),
      (.target // "-"),
      (.guest // "-" | tostring),
      (.schedule // "*/15"),
      (.comment // "-" | .[0:30])
    ]) | @tsv' | column -t

  local count
  count=$(echo "$result" | jq '.data | length')
  output_var "REPLICATION_COUNT" "$count"
  output_json "$(echo "$result" | jq '.data')"
  log_info "Found ${count} replication job(s)"
}

action_replication_create() {
  require_setting "VMID"        "VM/container ID"
  require_setting "TARGET_NODE" "Target node for replication"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local vmid="${PLUGIN_VMID}"
  local target="${PLUGIN_TARGET_NODE}"
  local schedule="${PLUGIN_SCHEDULE:-*/15}"
  local rate="${PLUGIN_RATE:-}"
  local comment="${PLUGIN_COMMENT:-}"

  # Replication ID format: <guest>-<jobnum>
  local rep_id="${vmid}-0"

  local args=(-d "id=${rep_id}" -d "target=${target}" -d "type=local")
  args+=(--data-urlencode "schedule=${schedule}")
  [[ -n "$rate" ]]    && args+=(-d "rate=${rate}")
  [[ -n "$comment" ]] && args+=(--data-urlencode "comment=${comment}")

  pve_post "/cluster/replication" "${args[@]}" >/dev/null
  output_var "REPLICATION_ID" "$rep_id"
  log_info "Replication job '${rep_id}' created: ${PLUGIN_NODE} -> ${target}"
}

action_replication_status() {
  local vmid="${PLUGIN_VMID:-}"

  local result
  result=$(pve_get "/cluster/replication")

  if [[ -n "$vmid" ]]; then
    result=$(echo "$result" | jq --arg v "$vmid" '{data: [.data[] | select(.guest == ($v | tonumber))]}')
  fi

  echo "$result" | jq '.data[] | {
    id, type, source, target, guest,
    schedule: .schedule,
    last_sync: (if .last_sync then (.last_sync | todate) else "never" end),
    next_sync: (if .next_sync then (.next_sync | todate) else "-" end),
    duration: .duration,
    fail_count: .fail_count
  }'

  output_json "$(echo "$result" | jq '.data')"
}
