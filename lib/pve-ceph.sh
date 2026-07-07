#!/usr/bin/env bash
# =============================================================================
# pve-ceph.sh — Ceph cluster management
# =============================================================================
# Actions: ceph-status, ceph-pool-list, ceph-pool-create, ceph-osd-create
# =============================================================================

[[ -n "${_PVE_CEPH_LOADED:-}" ]] && return 0
readonly _PVE_CEPH_LOADED=1

action_ceph_status() {
  local node="${PLUGIN_NODE}"
  local result
  result=$(pve_get "/nodes/${node}/ceph/status")

  echo "$result" | jq '.data | {
    health: .health.status,
    checks: [.health.checks // {} | keys[]],
    mon_count: (.monmap.mons // [] | length),
    osd_total: .osdmap.osdmap.num_osds,
    osd_up: .osdmap.osdmap.num_up_osds,
    osd_in: .osdmap.osdmap.num_in_osds,
    pg_count: .pgmap.num_pgs,
    data_bytes: .pgmap.data_bytes,
    used_bytes: .pgmap.bytes_used,
    avail_bytes: .pgmap.bytes_avail
  }'

  output_json "$(echo "$result" | jq '.data')"
  log_info "Ceph status retrieved"
}

action_ceph_pool_list() {
  local node="${PLUGIN_NODE}"
  local result
  result=$(pve_get "/nodes/${node}/ceph/pool")

  echo "$result" | jq -r '
    ["POOL","SIZE","MIN_SIZE","PG_NUM","BYTES_USED","CRUSH_RULE"],
    (.data[] | [
      .pool_name,
      (.size // 0 | tostring),
      (.min_size // 0 | tostring),
      (.pg_num // 0 | tostring),
      ((.bytes_used // 0) / 1073741824 * 10 | floor / 10 | tostring + "GB"),
      (.crush_rule_name // "-")
    ]) | @tsv' | column -t

  local count
  count=$(echo "$result" | jq '.data | length')
  output_var "CEPH_POOL_COUNT" "$count"
  output_json "$(echo "$result" | jq '.data')"
  log_info "Found ${count} Ceph pool(s)"
}

action_ceph_pool_create() {
  require_setting "CEPH_POOL" "Pool name"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}"
  local pool="${PLUGIN_CEPH_POOL}"
  local size="${PLUGIN_CEPH_SIZE:-3}"
  local min_size="${PLUGIN_CEPH_MIN_SIZE:-2}"
  local pg_num="${PLUGIN_PG_NUM:-128}"
  local application="${PLUGIN_APPLICATION:-rbd}"

  local args=(-d "name=${pool}" -d "size=${size}" -d "min_size=${min_size}")
  args+=(-d "pg_num=${pg_num}" -d "application=${application}")

  # Ceph pool creation is async (PG creation runs in the background). Poll the
  # task so we don't report the pool ready before it actually is.
  pve_post_task "/nodes/${node}/ceph/pool" "${args[@]}"
  output_var "CEPH_POOL" "$pool"
  log_info "Ceph pool '${pool}' created (size=${size}, pg_num=${pg_num})"
}

action_ceph_osd_create() {
  require_setting "CEPH_DEV" "Device path (e.g. /dev/sdb)"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}"
  local dev="${PLUGIN_CEPH_DEV}"
  local db_dev="${PLUGIN_CEPH_DB_DEV:-}"
  local wal_dev="${PLUGIN_CEPH_WAL_DEV:-}"

  local args=(-d "dev=${dev}")
  [[ -n "$db_dev" ]]  && args+=(-d "db_dev=${db_dev}")
  [[ -n "$wal_dev" ]] && args+=(-d "wal_dev=${wal_dev}")

  log_info "Creating OSD on ${dev}"
  pve_post_task "/nodes/${node}/ceph/osd" "${args[@]}"
  log_info "OSD created on ${dev}"
}
