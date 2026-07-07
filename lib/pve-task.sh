#!/usr/bin/env bash
# =============================================================================
# pve-task.sh — Task management
# =============================================================================
# Actions: task-list, task-log
# =============================================================================

[[ -n "${_PVE_TASK_LOADED:-}" ]] && return 0
readonly _PVE_TASK_LOADED=1

action_task_list() {
  local node="${PLUGIN_NODE}"
  local limit="${PLUGIN_LIMIT:-30}"
  local source="${PLUGIN_TASK_SOURCE:-}"
  local vmid="${PLUGIN_VMID:-}"
  local typefilter="${PLUGIN_TASK_TYPE:-}"

  local url="/nodes/${node}/tasks?limit=${limit}"
  [[ -n "$source" ]]     && url="${url}&source=${source}"
  [[ -n "$vmid" ]]       && url="${url}&vmid=${vmid}"
  [[ -n "$typefilter" ]] && url="${url}&typefilter=${typefilter}"

  local result
  result=$(pve_get "$url")

  echo "$result" | jq -r '
    ["UPID","TYPE","STATUS","USER","STARTTIME","NODE"],
    (.data[] | [
      (.upid // "-" | split(":") | .[6:7] | join(":")),
      (.type // "-"),
      (.status // "running"),
      (.user // "-"),
      (if .starttime then (.starttime | todate) else "-" end),
      (.node // "-")
    ]) | @tsv' | column -t

  local count
  count=$(echo "$result" | jq '.data | length')
  output_var "TASK_COUNT" "$count"
  output_json "$(echo "$result" | jq '.data')"
  log_info "Found ${count} task(s)"
}

action_task_log() {
  require_setting "TASK_UPID" "Task UPID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}"
  local upid="${PLUGIN_TASK_UPID}"
  local limit="${PLUGIN_LIMIT:-500}"

  local result
  result=$(pve_get "/nodes/${node}/tasks/${upid}/log?limit=${limit}")

  echo "$result" | jq -r '.data[] | .t // empty'

  # Also get status
  local status_result
  status_result=$(pve_get "/nodes/${node}/tasks/${upid}/status")
  local status exitstatus
  status=$(echo "$status_result" | jq -r '.data.status')
  exitstatus=$(echo "$status_result" | jq -r '.data.exitstatus // empty')

  output_var "TASK_STATUS" "$status"
  [[ -n "$exitstatus" ]] && output_var "TASK_EXITSTATUS" "$exitstatus"
  log_info "Task status: ${status}${exitstatus:+ (${exitstatus})}"
}
