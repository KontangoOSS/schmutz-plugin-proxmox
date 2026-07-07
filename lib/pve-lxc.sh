#!/usr/bin/env bash
# =============================================================================
# pve-lxc.sh — LXC container actions
# =============================================================================
# Actions: lxc-list, lxc-get, lxc-create, lxc-destroy, lxc-start, lxc-stop,
#          lxc-restart, lxc-status, lxc-resize, lxc-interfaces
# =============================================================================

[[ -n "${_PVE_LXC_LOADED:-}" ]] && return 0
readonly _PVE_LXC_LOADED=1

action_lxc_list() {
  local node="${PLUGIN_NODE}"
  local filter="${PLUGIN_FILTER:-}"

  local result
  result=$(pve_get "/nodes/${node}/lxc")
  local items
  items=$(echo "$result" | jq -r '.data')

  if [[ -n "$filter" ]]; then
    items=$(echo "$items" | jq --arg f "$filter" '[.[] | select(.name // "" | test($f; "i"))]')
  fi

  local count
  count=$(echo "$items" | jq 'length')

  # Pretty table
  echo "$items" | jq -r '
    ["VMID","NAME","STATUS","CPU","MEM(MB)","DISK(GB)"],
    (.[] | [
      .vmid,
      (.name // "-"),
      .status,
      (.cpus // 0 | tostring),
      ((.maxmem // 0) / 1048576 | floor | tostring),
      ((.maxdisk // 0) / 1073741824 * 10 | floor / 10 | tostring)
    ]) | @tsv' | column -t

  output_var "CONTAINER_COUNT" "$count"
  output_json "$(echo "$items" | jq '.')"
  log_info "Found ${count} container(s)"
}

action_lxc_get() {
  require_setting "VMID" "Container ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local config
  config=$(pve_get "/nodes/${node}/lxc/${vmid}/config")
  echo "$config" | jq '.data'
  output_json "$(echo "$config" | jq '.data')"
}

action_lxc_create() {
  require_setting "HOSTNAME"   "Container hostname"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}"
  local vmid="${PLUGIN_VMID:-}"
  local auto_vmid=false

  # Auto-assign VMID if not provided
  if [[ -z "$vmid" ]]; then
    auto_vmid=true
    vmid=$(find_next_vmid) || log_fatal "Failed to get next VMID"
    log_info "Auto-assigned VMID: ${vmid}"
  fi
  local hostname="${PLUGIN_HOSTNAME}"
  local ostemplate="${PLUGIN_OSTEMPLATE:-local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst}"
  local storage="${PLUGIN_STORAGE:-local-zfs}"
  local rootfs_size="${PLUGIN_ROOTFS_SIZE:-8}"
  local memory="${PLUGIN_MEMORY:-2048}"
  local swap="${PLUGIN_SWAP:-512}"
  local cores="${PLUGIN_CORES:-2}"
  local network="${PLUGIN_NETWORK:-name=eth0,bridge=vmbr0,ip=dhcp}"
  local unprivileged="${PLUGIN_UNPRIVILEGED:-1}"
  local password="${PLUGIN_PASSWORD:-}"
  local start="${PLUGIN_START_ON_CREATE:-true}"
  local features="${PLUGIN_FEATURES:-nesting=1}"

  # Retry loop for auto-VMID race conditions (concurrent builds may claim same ID)
  local max_retries=5
  local attempt=0
  while true; do
    attempt=$((attempt + 1))

    log_info "Creating LXC ${vmid} (${hostname}) on ${node}"
    log_info "  cores=${cores} memory=${memory}MB disk=${rootfs_size}GB"

    local args=()
    args+=(-d "vmid=${vmid}")
    args+=(-d "hostname=${hostname}")
    args+=(-d "ostemplate=${ostemplate}")
    args+=(-d "storage=${storage}")
    args+=(-d "rootfs=${storage}:${rootfs_size}")
    args+=(-d "memory=${memory}")
    args+=(-d "swap=${swap}")
    args+=(-d "cores=${cores}")
    args+=(--data-urlencode "net0=${network}")
    args+=(-d "unprivileged=${unprivileged}")
    args+=(--data-urlencode "features=${features}")
    [[ -n "$password" ]] && args+=(-d "password=${password}")
    [[ "$start" == "true" ]] && args+=(-d "start=1")

    # Extra args: comma-separated key=value pairs
    if [[ -n "${PLUGIN_EXTRA_ARGS:-}" ]]; then
      IFS=',' read -ra extras <<< "${PLUGIN_EXTRA_ARGS}"
      for extra in "${extras[@]}"; do
        args+=(-d "$extra")
      done
    fi

    # Capture stderr so we can tell a VMID collision (retryable when we
    # auto-assigned) apart from a real error like a missing template/storage,
    # which must be surfaced immediately rather than retried blindly.
    local create_err
    if create_err=$(pve_post_task "/nodes/${node}/lxc" "${args[@]}" 2>&1); then
      [[ -n "$create_err" ]] && log_debug "$create_err"
      break
    fi

    local is_conflict=false
    echo "$create_err" | grep -qiE 'already exists|config file already' && is_conflict=true

    if [[ "$auto_vmid" == "true" && "$is_conflict" == "true" && $attempt -lt $max_retries ]]; then
      log_warn "VMID ${vmid} already in use (attempt ${attempt}/${max_retries}), retrying with a new ID..."
      sleep $((attempt))
      vmid=$(find_next_vmid) || log_fatal "Failed to get next VMID"
      log_info "Retrying with VMID: ${vmid}"
    else
      # Real failure (bad template, missing storage, perms) — show the reason.
      log_error "Failed to create LXC ${vmid}: ${create_err}"
      log_fatal "lxc-create failed on attempt ${attempt}"
    fi
  done

  # Get status and IP
  local ct_status
  ct_status=$(pve_get "/nodes/${node}/lxc/${vmid}/status/current" | pve_field "status")
  log_info "Container ${vmid} status: ${ct_status}"

  output_var "PROXMOX_VMID" "$vmid"
  output_var "PROXMOX_NODE" "$node"
  output_var "PROXMOX_STATUS" "$ct_status"

  if [[ "$start" == "true" ]]; then
    local ip
    if ip=$(get_guest_ip "$vmid" 15 3); then
      output_var "PROXMOX_IP" "$ip"
      log_info "Container IP: ${ip}"
    fi
  fi

  # Opt-in: bring the guest fully up to date right after create. Off by
  # default so create stays fast; requires the container running + SSH creds
  # (pct exec runs on the host). Only Debian/Ubuntu (apt) guests.
  if [[ "${PLUGIN_UPDATE_ON_CREATE:-false}" == "true" ]]; then
    if [[ "$start" != "true" ]]; then
      log_warn "update_on_create set but start_on_create is false; skipping update"
    else
      lxc_update_guest "$vmid"
    fi
  fi

  log_info "LXC ${vmid} created"
}

# ── Post-create: fully update an apt-based guest ─────────────────────────
# Runs update + full dist-upgrade inside the container via pct exec.
# Waits for apt locks (cloud-init/unattended-upgrades may hold them on boot).

lxc_update_guest() {
  local vmid="$1"
  export PLUGIN_VMID="$vmid"

  log_info "Updating container ${vmid} (apt update && dist-upgrade)..."
  local script='set -e
for i in $(seq 1 30); do
  fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
  echo "waiting for apt lock ($i)..."; sleep 5
done
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade
apt-get -y -qq autoremove
echo "UPDATED: $(dpkg -l | grep -c ^ii) packages installed"'

  if pve_exec_quiet "$script"; then
    output_var "PROXMOX_UPDATED" "true"
    log_info "Container ${vmid} fully updated"
  else
    output_var "PROXMOX_UPDATED" "false"
    log_error "Container ${vmid} update failed (non-fatal; container still created)"
  fi
}

action_lxc_destroy() {
  require_setting "VMID" "Container ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"

  # Check if it exists
  local status_result
  if ! status_result=$(pve_get "/nodes/${node}/lxc/${vmid}/status/current" 2>/dev/null); then
    log_info "Container ${vmid} does not exist"
    return 0
  fi

  # Stop if running
  local current
  current=$(echo "$status_result" | pve_field "status")
  if [[ "$current" == "running" ]]; then
    log_info "Stopping container ${vmid} first..."
    pve_post_task "/nodes/${node}/lxc/${vmid}/status/stop"
  fi

  log_info "Deleting container ${vmid}"
  local result upid
  result=$(pve_delete "/nodes/${node}/lxc/${vmid}")
  upid=$(echo "$result" | jq -r '.data // empty')
  [[ -n "$upid" && "$upid" != "null" ]] && wait_for_task "$upid"

  log_info "Container ${vmid} deleted"
}

action_lxc_start() {
  require_setting "VMID" "Container ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  log_info "Starting container ${vmid}"
  pve_post_task "/nodes/${node}/lxc/${vmid}/status/start"

  local ip
  if ip=$(get_guest_ip "$vmid" 10 3); then
    output_var "PROXMOX_IP" "$ip"
    log_info "Container IP: ${ip}"
  fi
}

action_lxc_stop() {
  require_setting "VMID" "Container ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  log_info "Stopping container ${vmid}"
  pve_post_task "/nodes/${node}/lxc/${vmid}/status/stop"
}

action_lxc_restart() {
  require_setting "VMID" "Container ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  log_info "Restarting container ${vmid}"
  pve_post_task "/nodes/${node}/lxc/${vmid}/status/reboot"

  local ip
  if ip=$(get_guest_ip "$vmid" 10 3); then
    output_var "PROXMOX_IP" "$ip"
    log_info "Container IP: ${ip}"
  fi
}

action_lxc_status() {
  require_setting "VMID" "Container ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local result
  result=$(pve_get "/nodes/${node}/lxc/${vmid}/status/current")

  echo "$result" | jq '.data | {vmid, status, name, pid, cpus, uptime,
    mem_mb: ((.mem // 0) / 1048576 | floor),
    maxmem_mb: ((.maxmem // 0) / 1048576 | floor),
    cpu_pct: ((.cpu // 0) * 100 * 10 | floor / 10)}'

  local status
  status=$(echo "$result" | pve_field "status")
  output_var "PROXMOX_STATUS" "$status"
  output_json "$(echo "$result" | jq '.data')"
}

action_lxc_resize() {
  require_setting "VMID" "Container ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local changed=0

  # CPU and memory via config update
  local config_args=()
  if [[ -n "${PLUGIN_CORES:-}" ]]; then
    config_args+=(-d "cores=${PLUGIN_CORES}")
    log_info "Setting cores to ${PLUGIN_CORES}"
    changed=1
  fi
  if [[ -n "${PLUGIN_MEMORY:-}" ]]; then
    config_args+=(-d "memory=${PLUGIN_MEMORY}")
    log_info "Setting memory to ${PLUGIN_MEMORY}MB"
    changed=1
  fi

  if [[ ${#config_args[@]} -gt 0 ]]; then
    pve_put "/nodes/${node}/lxc/${vmid}/config" "${config_args[@]}"
  fi

  # Disk resize (separate endpoint). This one is ASYNC — it returns a UPID —
  # so we must poll the task, otherwise callers see the old size right after.
  # --data-urlencode on size: increment values like "+2G" contain a '+', which
  # -d form-encodes as a space and Proxmox's regex then rejects.
  if [[ -n "${PLUGIN_DISK:-}" ]]; then
    log_info "Resizing disk to ${PLUGIN_DISK}"
    local resize_result resize_upid
    resize_result=$(pve_put "/nodes/${node}/lxc/${vmid}/resize" \
      -d "disk=rootfs" --data-urlencode "size=${PLUGIN_DISK}")
    resize_upid=$(echo "$resize_result" | jq -r '.data // empty')
    if [[ -n "$resize_upid" && "$resize_upid" != "null" ]]; then
      wait_for_task "$resize_upid"
    fi
    changed=1
  fi

  if [[ $changed -eq 0 ]]; then
    log_warn "No resize parameters set (cores, memory, disk)"
  else
    log_info "Container ${vmid} resized"
  fi
}

action_lxc_interfaces() {
  require_setting "VMID" "Container ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local result
  result=$(pve_get "/nodes/${node}/lxc/${vmid}/interfaces")

  echo "$result" | jq '.data[] | {name, "inet-address", "inet6-address", hwaddr}'

  local ip
  ip=$(echo "$result" | jq -r \
    '[.data[]? | select(.name != "lo") | .["inet-address"]? // empty] | first // empty')
  if [[ -n "$ip" ]]; then
    output_var "PROXMOX_IP" "$ip"
    log_info "Primary IP: ${ip}"
  fi
}
