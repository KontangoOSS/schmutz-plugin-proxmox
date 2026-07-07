#!/usr/bin/env bash
# =============================================================================
# pve-network-mgmt.sh — Network and SDN management
# =============================================================================
# Actions: bridge-create, bridge-delete, vlan-create, sdn-zone-list,
#          sdn-zone-create, sdn-vnet-create, sdn-subnet-create, network-reload
# =============================================================================

[[ -n "${_PVE_NETWORK_MGMT_LOADED:-}" ]] && return 0
readonly _PVE_NETWORK_MGMT_LOADED=1

action_bridge_create() {
  require_setting "IFACE" "Bridge interface name (e.g. vmbr1)"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}"
  local iface="${PLUGIN_IFACE}"
  local cidr="${PLUGIN_CIDR:-}"
  local gateway="${PLUGIN_GATEWAY:-}"
  local bridge_ports="${PLUGIN_BRIDGE_PORTS:-}"
  local autostart="${PLUGIN_AUTOSTART:-true}"
  local comment="${PLUGIN_COMMENT:-}"

  local args=(-d "iface=${iface}" -d "type=bridge")
  [[ -n "$cidr" ]]         && args+=(--data-urlencode "cidr=${cidr}")
  [[ -n "$gateway" ]]      && args+=(-d "gateway=${gateway}")
  [[ -n "$bridge_ports" ]] && args+=(-d "bridge_ports=${bridge_ports}")
  [[ "$autostart" == "true" ]] && args+=(-d "autostart=1")
  [[ -n "$comment" ]]      && args+=(--data-urlencode "comment=${comment}")

  pve_post "/nodes/${node}/network" "${args[@]}" >/dev/null
  log_info "Bridge '${iface}' created on ${node}"
}

action_bridge_delete() {
  require_setting "IFACE" "Interface name to delete"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}"
  local iface="${PLUGIN_IFACE}"

  pve_delete "/nodes/${node}/network/${iface}" >/dev/null
  log_info "Interface '${iface}' deleted from ${node}"
}

action_vlan_create() {
  require_setting "IFACE"   "VLAN interface (e.g. eno1.100)"
  require_setting "VLAN_ID" "VLAN tag number"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}"
  local iface="${PLUGIN_IFACE}"
  local raw_device="${PLUGIN_RAW_DEVICE:-}"
  local cidr="${PLUGIN_CIDR:-}"
  local gateway="${PLUGIN_GATEWAY:-}"

  local args=(-d "iface=${iface}" -d "type=vlan")
  [[ -n "$raw_device" ]] && args+=(-d "vlan-raw-device=${raw_device}")
  [[ -n "$cidr" ]]       && args+=(--data-urlencode "cidr=${cidr}")
  [[ -n "$gateway" ]]    && args+=(-d "gateway=${gateway}")

  pve_post "/nodes/${node}/network" "${args[@]}" >/dev/null
  log_info "VLAN interface '${iface}' created"
}

action_sdn_zone_list() {
  local result
  result=$(pve_get "/cluster/sdn/zones")

  echo "$result" | jq -r '
    ["ZONE","TYPE","NODES","MTU","DNS","DNSZONE"],
    (.data[] | [
      .zone,
      .type,
      (.nodes // "all"),
      (.mtu // "-" | tostring),
      (.dns // "-"),
      (.dnszone // "-")
    ]) | @tsv' | column -t

  output_json "$(echo "$result" | jq '.data')"
  log_info "Found $(echo "$result" | jq '.data | length') SDN zone(s)"
}

action_sdn_zone_create() {
  require_setting "SDN_ZONE" "Zone identifier"
  require_setting "SDN_TYPE" "Zone type (simple, vlan, qinq, vxlan, evpn)"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local zone="${PLUGIN_SDN_ZONE}"
  local ztype="${PLUGIN_SDN_TYPE}"
  local nodes="${PLUGIN_NODES:-}"
  local mtu="${PLUGIN_MTU:-}"
  local bridge="${PLUGIN_BRIDGE:-}"

  local args=(-d "zone=${zone}" -d "type=${ztype}")
  [[ -n "$nodes" ]]  && args+=(-d "nodes=${nodes}")
  [[ -n "$mtu" ]]    && args+=(-d "mtu=${mtu}")
  [[ -n "$bridge" ]] && args+=(-d "bridge=${bridge}")

  pve_post "/cluster/sdn/zones" "${args[@]}" >/dev/null
  log_info "SDN zone '${zone}' (${ztype}) created"
}

action_sdn_vnet_create() {
  require_setting "SDN_VNET" "VNet name"
  require_setting "SDN_ZONE" "Zone this VNet belongs to"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local vnet="${PLUGIN_SDN_VNET}"
  local zone="${PLUGIN_SDN_ZONE}"
  local alias="${PLUGIN_ALIAS:-}"
  local tag="${PLUGIN_VLAN_TAG:-}"

  local args=(-d "vnet=${vnet}" -d "zone=${zone}")
  [[ -n "$alias" ]] && args+=(--data-urlencode "alias=${alias}")
  [[ -n "$tag" ]]   && args+=(-d "tag=${tag}")

  pve_post "/cluster/sdn/vnets" "${args[@]}" >/dev/null
  log_info "VNet '${vnet}' created in zone '${zone}'"
}

action_sdn_subnet_create() {
  require_setting "SDN_VNET"  "VNet name"
  require_setting "SDN_SUBNET" "Subnet CIDR (e.g. 10.0.0.0/24)"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local vnet="${PLUGIN_SDN_VNET}"
  local subnet="${PLUGIN_SDN_SUBNET}"
  local gateway="${PLUGIN_GATEWAY:-}"
  local snat="${PLUGIN_SNAT:-false}"
  local dnszoneprefix="${PLUGIN_DNS_PREFIX:-}"

  # subnet is a CIDR (10.0.0.0/24) — the '/' must be urlencoded.
  local args=(--data-urlencode "subnet=${subnet}" -d "type=subnet")
  [[ -n "$gateway" ]]        && args+=(-d "gateway=${gateway}")
  [[ "$snat" == "true" ]]    && args+=(-d "snat=1")
  [[ -n "$dnszoneprefix" ]]  && args+=(-d "dnszoneprefix=${dnszoneprefix}")

  pve_post "/cluster/sdn/vnets/${vnet}/subnets" "${args[@]}" >/dev/null
  log_info "Subnet '${subnet}' created in VNet '${vnet}'"
}

action_network_reload() {
  local node="${PLUGIN_NODE}"
  log_info "Reloading network configuration on ${node}"
  # Applying pending network changes (ifreload) is async — it returns a UPID.
  # Poll it so a failed reload (e.g. a bad bridge) surfaces instead of a false OK.
  local result upid
  result=$(pve_put "/nodes/${node}/network")
  upid=$(echo "$result" | jq -r '.data // empty')
  if [[ -n "$upid" && "$upid" != "null" ]]; then
    wait_for_task "$upid"
  fi
  log_info "Network configuration reloaded"
}
