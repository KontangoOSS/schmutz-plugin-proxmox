#!/usr/bin/env bash
# =============================================================================
# pve-console.sh — Console access (VNC/SPICE)
# =============================================================================
# Actions: vnc-url, spice-config
# =============================================================================

[[ -n "${_PVE_CONSOLE_LOADED:-}" ]] && return 0
readonly _PVE_CONSOLE_LOADED=1

action_vnc_url() {
  require_setting "VMID" "VM/container ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local gtype
  gtype=$(_guest_type_path) || exit $EXIT_API

  local result
  result=$(pve_post "/nodes/${node}/${gtype}/${vmid}/vncproxy" \
    -d "websocket=1")

  local ticket port
  ticket=$(echo "$result" | jq -r '.data.ticket // empty')
  port=$(echo "$result" | jq -r '.data.port // empty')

  if [[ -n "$ticket" && -n "$port" ]]; then
    local ws_url="${PLUGIN_API_URL}/?console=${gtype}&novnc=1&vmid=${vmid}&node=${node}&port=${port}&vncticket=$(jq -rn --arg t "$ticket" '$t | @uri')"
    output_var "VNC_TICKET" "$ticket"
    output_var "VNC_PORT" "$port"
    output_var "VNC_URL" "$ws_url"
    echo "$ws_url"
    log_info "VNC proxy started on port ${port}"
  else
    log_error "Failed to create VNC proxy"
    echo "$result" | jq '.data'
    return 1
  fi
}

action_spice_config() {
  require_setting "VMID" "VM/container ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local gtype
  gtype=$(_guest_type_path) || exit $EXIT_API

  local result
  result=$(pve_post "/nodes/${node}/${gtype}/${vmid}/spiceproxy")

  local proxy_type host
  proxy_type=$(echo "$result" | jq -r '.data.type // empty')
  host=$(echo "$result" | jq -r '.data.host // empty')

  if [[ -n "$proxy_type" ]]; then
    echo "$result" | jq '.data'
    output_json "$(echo "$result" | jq '.data')"
    log_info "SPICE config generated (host: ${host})"
  else
    log_error "Failed to create SPICE proxy"
    echo "$result" | jq '.data'
    return 1
  fi
}
