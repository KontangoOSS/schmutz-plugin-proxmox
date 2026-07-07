#!/usr/bin/env bash
# =============================================================================
# pve-storage-mgmt.sh — Storage management actions
# =============================================================================
# Actions: storage-create, storage-delete, iso-upload, iso-list,
#          template-download, template-create, volume-list, disk-import
# =============================================================================

[[ -n "${_PVE_STORAGE_MGMT_LOADED:-}" ]] && return 0
readonly _PVE_STORAGE_MGMT_LOADED=1

action_storage_create() {
  require_setting "STORAGE_ID"   "Storage identifier"
  require_setting "STORAGE_TYPE" "Storage type (dir, lvm, lvmthin, nfs, cifs, zfspool, etc.)"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local sid="${PLUGIN_STORAGE_ID}"
  local stype="${PLUGIN_STORAGE_TYPE}"
  local content="${PLUGIN_CONTENT:-images,rootdir}"
  local path="${PLUGIN_STORAGE_PATH:-}"
  local server="${PLUGIN_SERVER:-}"
  local export="${PLUGIN_EXPORT:-}"
  local pool="${PLUGIN_ZPOOL:-}"
  local vgname="${PLUGIN_VGNAME:-}"
  local thinpool="${PLUGIN_THINPOOL:-}"
  local nodes="${PLUGIN_NODES:-}"

  local args=(-d "storage=${sid}" -d "type=${stype}" -d "content=${content}")
  [[ -n "$path" ]]     && args+=(--data-urlencode "path=${path}")
  [[ -n "$server" ]]   && args+=(-d "server=${server}")
  [[ -n "$export" ]]   && args+=(--data-urlencode "export=${export}")
  [[ -n "$pool" ]]     && args+=(-d "pool=${pool}")
  [[ -n "$vgname" ]]   && args+=(-d "vgname=${vgname}")
  [[ -n "$thinpool" ]] && args+=(-d "thinpool=${thinpool}")
  [[ -n "$nodes" ]]    && args+=(-d "nodes=${nodes}")

  pve_post "/storage" "${args[@]}" >/dev/null
  output_var "PROXMOX_STORAGE" "$sid"
  log_info "Storage '${sid}' (${stype}) created"
}

action_storage_delete() {
  require_setting "STORAGE_ID" "Storage identifier"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local sid="${PLUGIN_STORAGE_ID}"
  pve_delete "/storage/${sid}" >/dev/null
  log_info "Storage '${sid}' deleted"
}

action_iso_upload() {
  require_setting "ISO_URL" "URL of ISO to download"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}"
  local storage="${PLUGIN_STORAGE:-local}"
  local url="${PLUGIN_ISO_URL}"
  local filename="${PLUGIN_FILENAME:-}"

  # Derive filename from URL if not specified
  if [[ -z "$filename" ]]; then
    filename="${url##*/}"
    filename="${filename%%\?*}"
  fi

  log_info "Downloading ISO '${filename}' to ${storage}"
  pve_post_task "/nodes/${node}/storage/${storage}/download-url" \
    --data-urlencode "url=${url}" \
    -d "filename=${filename}" \
    -d "content=iso"

  output_var "PROXMOX_ISO" "${storage}:iso/${filename}"
  log_info "ISO '${filename}' uploaded to ${storage}"
}

action_iso_list() {
  local node="${PLUGIN_NODE}"

  # Find storage pools that hold ISO content
  local storages
  storages=$(pve_get "/nodes/${node}/storage" \
    | jq -r '.data[] | select(.content // "" | test("iso")) | .storage')

  local all_isos="[]"
  for storage in $storages; do
    local result
    result=$(pve_get "/nodes/${node}/storage/${storage}/content?content=iso" \
      2>/dev/null || echo '{"data":[]}')
    all_isos=$(echo "$all_isos" "$(echo "$result" | jq '.data')" | jq -s 'add')
  done

  echo "$all_isos" | jq -r '
    ["VOLID","SIZE(MB)","FORMAT"],
    (.[] | [
      .volid,
      ((.size // 0) / 1048576 | floor | tostring),
      (.format // "-")
    ]) | @tsv' | column -t

  local count
  count=$(echo "$all_isos" | jq 'length')
  output_var "ISO_COUNT" "$count"
  output_json "$all_isos"
  log_info "Found ${count} ISO(s)"
}

action_template_download() {
  require_setting "TEMPLATE_URL" "URL to download template from"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}"
  local storage="${PLUGIN_STORAGE:-local}"
  local url="${PLUGIN_TEMPLATE_URL}"
  local filename="${PLUGIN_FILENAME:-}"

  if [[ -z "$filename" ]]; then
    filename="${url##*/}"
    filename="${filename%%\?*}"
  fi

  log_info "Downloading template '${filename}' to ${storage}"
  pve_post_task "/nodes/${node}/storage/${storage}/download-url" \
    --data-urlencode "url=${url}" \
    -d "filename=${filename}" \
    -d "content=vztmpl"

  output_var "PROXMOX_TEMPLATE" "${storage}:vztmpl/${filename}"
  log_info "Template '${filename}' downloaded to ${storage}"
}

action_template_create() {
  require_setting "VMID" "VM ID to convert to template"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  log_info "Converting VM ${vmid} to template"
  # Conversion relinks base images and can be async (UPID). Poll when we get
  # one so a later clone doesn't race a still-running template task.
  local result upid
  result=$(pve_post "/nodes/${node}/qemu/${vmid}/template")
  upid=$(echo "$result" | jq -r '.data // empty')
  if [[ -n "$upid" && "$upid" != "null" ]]; then
    wait_for_task "$upid"
  fi
  log_info "VM ${vmid} converted to template"
}

action_volume_list() {
  require_setting "STORAGE_ID" "Storage identifier"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}"
  local storage="${PLUGIN_STORAGE_ID}"
  local content="${PLUGIN_CONTENT:-}"

  local url="/nodes/${node}/storage/${storage}/content"
  [[ -n "$content" ]] && url="${url}?content=${content}"

  local result
  result=$(pve_get "$url")

  echo "$result" | jq -r '
    ["VOLID","SIZE(GB)","FORMAT","CONTENT","VMID"],
    (.data[] | [
      .volid,
      ((.size // 0) / 1073741824 * 10 | floor / 10 | tostring),
      (.format // "-"),
      (.content // "-"),
      (.vmid // "-" | tostring)
    ]) | @tsv' | column -t

  local count
  count=$(echo "$result" | jq '.data | length')
  output_var "VOLUME_COUNT" "$count"
  output_json "$(echo "$result" | jq '.data')"
  log_info "Found ${count} volume(s)"
}

action_disk_import() {
  require_setting "VMID"     "Target VM ID"
  require_setting "DISK_URL" "URL or path of disk image"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}" vmid="${PLUGIN_VMID}"
  local storage="${PLUGIN_STORAGE:-local-lvm}"
  local disk_url="${PLUGIN_DISK_URL}"
  local format="${PLUGIN_DISK_FORMAT:-raw}"

  log_info "Importing disk for VM ${vmid} from ${disk_url}"

  # Download the disk image to the node, then import via API
  # Proxmox doesn't have a direct import-from-URL API endpoint,
  # so we use the storage download-url and then attach
  local filename="vm-${vmid}-import.${format}"

  pve_post_task "/nodes/${node}/storage/${storage}/download-url" \
    --data-urlencode "url=${disk_url}" \
    -d "filename=${filename}" \
    -d "content=images"

  output_var "PROXMOX_DISK" "${storage}:${filename}"
  log_info "Disk imported to ${storage}:${filename}"
}
