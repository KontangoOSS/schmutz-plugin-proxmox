#!/usr/bin/env bash
# =============================================================================
# pve-node.sh — Node, cluster, storage, and network actions
# =============================================================================
# Actions: node-list, node-status, storage-list, template-list,
#          network-list, next-vmid, cluster-status, cluster-resources
# =============================================================================

[[ -n "${_PVE_NODE_LOADED:-}" ]] && return 0
readonly _PVE_NODE_LOADED=1

action_node_list() {
  local result
  result=$(pve_get "/nodes")

  echo "$result" | jq -r '
    ["NODE","STATUS","CPU","MEM(GB)","UPTIME"],
    (.data[] | [
      .node,
      .status,
      ((.cpu // 0) * 100 * 10 | floor / 10 | tostring + "%"),
      (((.mem // 0) / 1073741824 * 10 | floor / 10 | tostring) + "/" +
       ((.maxmem // 0) / 1073741824 * 10 | floor / 10 | tostring)),
      ((.uptime // 0) / 3600 | floor | tostring + "h")
    ]) | @tsv' | column -t

  local count
  count=$(echo "$result" | jq '.data | length')
  output_var "NODE_COUNT" "$count"
  output_json "$(echo "$result" | jq '.data')"
}

action_node_status() {
  local node="${PLUGIN_NODE}"
  local result
  result=$(pve_get "/nodes/${node}/status")

  echo "$result" | jq '.data | {
    hostname: (.hostname // empty),
    kernel: (.kversion // empty),
    cpumodel: (.cpuinfo.model // empty),
    cpus: (.cpuinfo.cpus // 0),
    loadavg: (.loadavg // []),
    mem_used_gb: ((.memory.used // 0) / 1073741824 * 10 | floor / 10),
    mem_total_gb: ((.memory.total // 0) / 1073741824 * 10 | floor / 10),
    swap_used_gb: ((.swap.used // 0) / 1073741824 * 10 | floor / 10),
    swap_total_gb: ((.swap.total // 0) / 1073741824 * 10 | floor / 10),
    rootfs_used_gb: ((.rootfs.used // 0) / 1073741824 * 10 | floor / 10),
    rootfs_total_gb: ((.rootfs.total // 0) / 1073741824 * 10 | floor / 10),
    uptime_hours: ((.uptime // 0) / 3600 | floor)
  }'

  output_json "$(echo "$result" | jq '.data')"
}

action_storage_list() {
  local node="${PLUGIN_NODE}"
  local result
  result=$(pve_get "/nodes/${node}/storage")

  echo "$result" | jq -r '
    ["STORAGE","TYPE","TOTAL(GB)","USED(GB)","AVAIL(GB)","CONTENT","ACTIVE"],
    (.data[] | [
      .storage,
      .type,
      ((.total // 0) / 1073741824 * 10 | floor / 10 | tostring),
      ((.used // 0) / 1073741824 * 10 | floor / 10 | tostring),
      ((.avail // 0) / 1073741824 * 10 | floor / 10 | tostring),
      (.content // "-"),
      (if .active == 1 then "yes" else "no" end)
    ]) | @tsv' | column -t

  output_json "$(echo "$result" | jq '.data')"
}

action_template_list() {
  local node="${PLUGIN_NODE}"

  # Find storage pools that hold vztmpl content
  local storages
  storages=$(pve_get "/nodes/${node}/storage" \
    | jq -r '.data[] | select(.content // "" | test("vztmpl")) | .storage')

  local all_templates="[]"
  for storage in $storages; do
    local result
    result=$(pve_get "/nodes/${node}/storage/${storage}/content?content=vztmpl" 2>/dev/null || echo '{"data":[]}')
    all_templates=$(echo "$all_templates" "$(echo "$result" | jq '.data')" \
      | jq -s 'add')
  done

  echo "$all_templates" | jq -r '
    ["TEMPLATE","SIZE(MB)","FORMAT"],
    (.[] | [
      .volid,
      ((.size // 0) / 1048576 | floor | tostring),
      (.format // "-")
    ]) | @tsv' | column -t

  local count
  count=$(echo "$all_templates" | jq 'length')
  output_var "TEMPLATE_COUNT" "$count"
  output_json "$all_templates"
  log_info "Found ${count} template(s)"
}

action_network_list() {
  local node="${PLUGIN_NODE}"
  local result
  result=$(pve_get "/nodes/${node}/network")

  echo "$result" | jq -r '
    ["IFACE","TYPE","CIDR","BRIDGE_PORTS","ACTIVE"],
    (.data[] | [
      .iface,
      .type,
      (.cidr // "-"),
      (.bridge_ports // "-"),
      (if .active == 1 then "yes" else "no" end)
    ]) | @tsv' | column -t

  output_json "$(echo "$result" | jq '.data')"
}

action_next_vmid() {
  local vmid
  vmid=$(find_next_vmid)
  echo "$vmid"
  output_var "NEXT_VMID" "$vmid"
  log_info "Next available VMID: ${vmid}"
}

action_cluster_status() {
  local result
  result=$(pve_get "/cluster/status")

  echo "$result" | jq '.data[] | {name, type, online: .online, quorate: .quorate, nodeid}'

  output_json "$(echo "$result" | jq '.data')"
}

action_cluster_resources() {
  local type_filter="${PLUGIN_RESOURCE_TYPE:-}"
  local url="/cluster/resources"
  [[ -n "$type_filter" ]] && url="${url}?type=${type_filter}"

  local result
  result=$(pve_get "$url")

  echo "$result" | jq -r '
    ["ID","TYPE","NODE","STATUS","CPU%","MEM(GB)","DISK(GB)","NAME"],
    (.data[] | [
      .id,
      .type,
      (.node // "-"),
      (.status // "-"),
      ((.cpu // 0) * 100 * 10 | floor / 10 | tostring),
      ((.maxmem // 0) / 1073741824 * 10 | floor / 10 | tostring),
      ((.maxdisk // 0) / 1073741824 * 10 | floor / 10 | tostring),
      (.name // "-")
    ]) | @tsv' | column -t

  local count
  count=$(echo "$result" | jq '.data | length')
  output_var "RESOURCE_COUNT" "$count"
  output_json "$(echo "$result" | jq '.data')"
  log_info "Found ${count} resource(s)"
}
