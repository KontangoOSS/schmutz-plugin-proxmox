#!/usr/bin/env bash
# =============================================================================
# pve-disk.sh — VM disk and PCI passthrough management
# =============================================================================
# Actions: vm-disk-add, vm-disk-resize, vm-disk-move, pci-passthrough, pci-list
# =============================================================================

[[ -n "${_PVE_DISK_LOADED:-}" ]] && return 0
readonly _PVE_DISK_LOADED=1

action_vm_disk_add() {
  require_setting "VMID" "VM ID"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local storage="${PLUGIN_STORAGE:-local-lvm}"
  local size="${PLUGIN_DISK_SIZE:-32}"
  local bus="${PLUGIN_DISK_BUS:-scsi}"
  local slot="${PLUGIN_DISK_SLOT:-1}"
  local format="${PLUGIN_DISK_FORMAT:-raw}"
  local cache="${PLUGIN_DISK_CACHE:-}"
  local iothread="${PLUGIN_IOTHREAD:-1}"

  local disk_key="${bus}${slot}"
  local disk_val="${storage}:${size},format=${format}"
  [[ -n "$cache" ]] && disk_val="${disk_val},cache=${cache}"
  [[ "$bus" == "scsi" ]] && disk_val="${disk_val},iothread=${iothread}"

  log_info "Adding disk ${disk_key}=${storage}:${size}GB to VM ${vmid}"
  pve_put "/nodes/${node}/qemu/${vmid}/config" \
    --data-urlencode "${disk_key}=${disk_val}"

  output_var "PROXMOX_DISK" "$disk_key"
  log_info "Disk ${disk_key} added to VM ${vmid}"
}

action_vm_disk_resize() {
  require_setting "VMID" "VM ID"
  require_setting "DISK" "Disk name (e.g. scsi0, virtio0)"
  require_setting "SIZE" "New size (e.g. +10G or 50G)"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local disk="${PLUGIN_DISK}"
  local size="${PLUGIN_SIZE}"

  log_info "Resizing ${disk} on VM ${vmid} to ${size}"
  # --data-urlencode: an increment size like "+10G" contains a '+' that -d
  # turns into a space, which Proxmox's regex rejects. The resize endpoint is
  # also async (returns a UPID), so poll it or we report success too early.
  local resize_result resize_upid
  resize_result=$(pve_put "/nodes/${node}/qemu/${vmid}/resize" \
    -d "disk=${disk}" --data-urlencode "size=${size}")
  resize_upid=$(echo "$resize_result" | jq -r '.data // empty')
  if [[ -n "$resize_upid" && "$resize_upid" != "null" ]]; then
    wait_for_task "$resize_upid"
  fi

  log_info "Disk ${disk} resized to ${size}"
}

action_vm_disk_move() {
  require_setting "VMID"           "VM ID"
  require_setting "DISK"           "Source disk (e.g. scsi0)"
  require_setting "TARGET_STORAGE" "Destination storage"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local disk="${PLUGIN_DISK}"
  local target="${PLUGIN_TARGET_STORAGE}"
  local delete_original="${PLUGIN_DELETE_ORIGINAL:-true}"
  local format="${PLUGIN_DISK_FORMAT:-}"

  log_info "Moving ${disk} from VM ${vmid} to ${target}"

  local args=(-d "disk=${disk}" -d "storage=${target}")
  [[ "$delete_original" == "true" ]] && args+=(-d "delete=1")
  [[ -n "$format" ]] && args+=(-d "format=${format}")

  pve_post_task "/nodes/${node}/qemu/${vmid}/move_disk" "${args[@]}"
  log_info "Disk ${disk} moved to ${target}"
}

action_pci_list() {
  local node="${PLUGIN_NODE}"
  local result
  result=$(pve_get "/nodes/${node}/hardware/pci")

  echo "$result" | jq -r '
    ["ID","CLASS","VENDOR","DEVICE","IOMMUGROUP","SUBSYSTEM"],
    (.data[] | [
      .id,
      (.class // "-"),
      (.vendor_name // .vendor // "-" | .[0:25]),
      (.device_name // .device // "-" | .[0:25]),
      (.iommugroup // -1 | tostring),
      (.subsystem_device // "-")
    ]) | @tsv' | column -t

  local count
  count=$(echo "$result" | jq '.data | length')
  output_var "PCI_COUNT" "$count"
  output_json "$(echo "$result" | jq '.data')"
  log_info "Found ${count} PCI device(s)"
}

action_pci_passthrough() {
  require_setting "VMID"   "VM ID"
  require_setting "PCI_ID" "PCI device ID (e.g. 0000:01:00.0)"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local pci_id="${PLUGIN_PCI_ID}"
  local slot="${PLUGIN_PCI_SLOT:-0}"
  local rombar="${PLUGIN_ROMBAR:-1}"
  local pcie="${PLUGIN_PCIE:-1}"

  local pci_val="${pci_id},rombar=${rombar},pcie=${pcie}"

  log_info "Passing through PCI ${pci_id} to VM ${vmid} as hostpci${slot}"
  pve_put "/nodes/${node}/qemu/${vmid}/config" \
    -d "hostpci${slot}=${pci_val}"

  log_info "PCI ${pci_id} attached to VM ${vmid}"
}
