#!/usr/bin/env bash
# =============================================================================
# pve-cloud-init.sh — Cloud-init configuration
# =============================================================================
# Actions: cloud-init-set, cloud-init-dump
# =============================================================================

[[ -n "${_PVE_CLOUD_INIT_LOADED:-}" ]] && return 0
readonly _PVE_CLOUD_INIT_LOADED=1

action_cloud_init_set() {
  require_setting "VMID" "VM ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local args=()
  local changed=0

  if [[ -n "${PLUGIN_CI_USER:-}" ]]; then
    args+=(-d "ciuser=${PLUGIN_CI_USER}")
    log_info "Setting cloud-init user: ${PLUGIN_CI_USER}"
    changed=1
  fi
  if [[ -n "${PLUGIN_CI_PASSWORD:-}" ]]; then
    args+=(-d "cipassword=${PLUGIN_CI_PASSWORD}")
    changed=1
  fi
  if [[ -n "${PLUGIN_SSH_KEYS:-}" ]]; then
    args+=(--data-urlencode "sshkeys=${PLUGIN_SSH_KEYS}")
    changed=1
  fi
  if [[ -n "${PLUGIN_IP_CONFIG:-}" ]]; then
    args+=(--data-urlencode "ipconfig0=${PLUGIN_IP_CONFIG}")
    log_info "Setting ipconfig0: ${PLUGIN_IP_CONFIG}"
    changed=1
  fi
  if [[ -n "${PLUGIN_NAMESERVER:-}" ]]; then
    args+=(-d "nameserver=${PLUGIN_NAMESERVER}")
    changed=1
  fi
  if [[ -n "${PLUGIN_SEARCHDOMAIN:-}" ]]; then
    args+=(-d "searchdomain=${PLUGIN_SEARCHDOMAIN}")
    changed=1
  fi

  # Add cloud-init drive if not already present
  if [[ -n "${PLUGIN_CI_STORAGE:-}" ]]; then
    args+=(-d "ide2=${PLUGIN_CI_STORAGE}:cloudinit")
    changed=1
  fi

  if [[ $changed -eq 0 ]]; then
    log_warn "No cloud-init parameters specified"
    return 0
  fi

  pve_put "/nodes/${node}/qemu/${vmid}/config" "${args[@]}"
  log_info "Cloud-init configured for VM ${vmid}"
}

action_cloud_init_dump() {
  require_setting "VMID" "VM ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local ci_type="${PLUGIN_CI_TYPE:-user}"

  local result
  result=$(pve_get "/nodes/${node}/qemu/${vmid}/cloudinit/dump?type=${ci_type}")

  echo "$result" | jq -r '.data // empty'
  output_json "$(echo "$result" | jq '.')"
}
