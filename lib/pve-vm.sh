#!/usr/bin/env bash
# =============================================================================
# pve-vm.sh — QEMU/KVM VM actions
# =============================================================================
# Actions: vm-list, vm-get, vm-create, vm-destroy, vm-start, vm-stop, vm-restart
# =============================================================================

[[ -n "${_PVE_VM_LOADED:-}" ]] && return 0
readonly _PVE_VM_LOADED=1

action_vm_list() {
  local node="${PLUGIN_NODE}"
  local filter="${PLUGIN_FILTER:-}"

  local result
  result=$(pve_get "/nodes/${node}/qemu")
  local items
  items=$(echo "$result" | jq -r '.data')

  if [[ -n "$filter" ]]; then
    items=$(echo "$items" | jq --arg f "$filter" '[.[] | select(.name // "" | test($f; "i"))]')
  fi

  local count
  count=$(echo "$items" | jq 'length')

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

  output_var "VM_COUNT" "$count"
  output_json "$(echo "$items" | jq '.')"
  log_info "Found ${count} VM(s)"
}

action_vm_get() {
  require_setting "VMID" "VM ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local config
  config=$(pve_get "/nodes/${node}/qemu/${vmid}/config")
  echo "$config" | jq '.data'
  output_json "$(echo "$config" | jq '.data')"
}

action_vm_create() {
  require_setting "VMID"    "VM ID"
  require_setting "VM_NAME" "VM name"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}"
  local vmid="${PLUGIN_VMID}"
  local name="${PLUGIN_VM_NAME}"
  local cores="${PLUGIN_CORES:-2}"
  local memory="${PLUGIN_MEMORY:-2048}"
  local storage="${PLUGIN_STORAGE:-local-zfs}"
  local disk_size="${PLUGIN_DISK_SIZE:-32}"
  local iso="${PLUGIN_ISO:-}"
  local bridge="${PLUGIN_BRIDGE:-vmbr0}"
  local bios="${PLUGIN_BIOS:-seabios}"
  local machine="${PLUGIN_MACHINE:-q35}"
  local scsihw="${PLUGIN_SCSIHW:-virtio-scsi-single}"
  local os_type="${PLUGIN_OS_TYPE:-l26}"
  local mac="${PLUGIN_MAC:-}"
  local ip="${PLUGIN_IP:-}"

  # Boot media must exist before we create a VM that depends on it, otherwise
  # the VM comes up with an empty CD drive and silently fails to install.
  if [[ -n "$iso" ]]; then
    log_info "Checking ISO ${iso} exists on ${node}..."
    if pve_iso_exists "$iso"; then
      log_info "  ISO found"
    else
      log_fatal "ISO not found: ${iso} (check 'iso-list' for available media)"
    fi
  fi

  log_info "Creating VM ${vmid} (${name}) on ${node}"
  log_info "  cores=${cores} memory=${memory}MB disk=${disk_size}GB"

  # NIC: provisioning owns MAC/IP. A pinned MAC keeps DHCP reservations and
  # firewall rules stable across rebuilds; ip= sets a cloud-init static addr.
  # Proxmox NIC syntax puts the MAC as the model's value: "virtio=<MAC>".
  local net0="model=virtio,bridge=${bridge}"
  [[ -n "$mac" ]] && net0="virtio=${mac},bridge=${bridge}"

  local args=()
  args+=(-d "vmid=${vmid}")
  args+=(-d "name=${name}")
  args+=(-d "cores=${cores}")
  args+=(-d "memory=${memory}")
  args+=(-d "bios=${bios}")
  args+=(-d "machine=${machine}")
  args+=(-d "scsihw=${scsihw}")
  args+=(-d "ostype=${os_type}")
  args+=(-d "scsi0=${storage}:${disk_size}")
  args+=(--data-urlencode "net0=${net0}")
  [[ -n "$ip" ]] && args+=(--data-urlencode "ipconfig0=ip=${ip}")
  # --data-urlencode: the ISO volid contains ':' and '/', which -d mangles into
  # a malformed "duplicate file key" error. urlencode preserves it.
  [[ -n "$iso" ]] && args+=(--data-urlencode "ide2=${iso},media=cdrom")
  [[ "${PLUGIN_START_ON_CREATE:-false}" == "true" ]] && args+=(-d "start=1")

  pve_post_task "/nodes/${node}/qemu" "${args[@]}"

  output_var "PROXMOX_VMID" "$vmid"
  output_var "PROXMOX_NODE" "$node"
  log_info "VM ${vmid} created"
}

action_vm_destroy() {
  require_setting "VMID" "VM ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"

  # Check if it exists
  local status_result
  if ! status_result=$(pve_get "/nodes/${node}/qemu/${vmid}/status/current" 2>/dev/null); then
    log_info "VM ${vmid} does not exist"
    return 0
  fi

  # Stop if running
  local current
  current=$(echo "$status_result" | pve_field "status")
  if [[ "$current" == "running" ]]; then
    log_info "Stopping VM ${vmid} first..."
    pve_post_task "/nodes/${node}/qemu/${vmid}/status/stop"
  fi

  log_info "Deleting VM ${vmid}"
  local result upid
  result=$(pve_delete "/nodes/${node}/qemu/${vmid}")
  upid=$(echo "$result" | jq -r '.data // empty')
  [[ -n "$upid" && "$upid" != "null" ]] && wait_for_task "$upid"

  log_info "VM ${vmid} deleted"
}

action_vm_start() {
  require_setting "VMID" "VM ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  log_info "Starting VM ${vmid}"
  pve_post_task "/nodes/${node}/qemu/${vmid}/status/start"
}

action_vm_stop() {
  require_setting "VMID" "VM ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  log_info "Stopping VM ${vmid}"
  pve_post_task "/nodes/${node}/qemu/${vmid}/status/stop"
}

action_vm_restart() {
  require_setting "VMID" "VM ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  log_info "Restarting VM ${vmid}"
  pve_post_task "/nodes/${node}/qemu/${vmid}/status/reboot"
}
