#!/usr/bin/env bash
# =============================================================================
# pve-metrics.sh — Metrics server management
# =============================================================================
# Actions: metrics-server-create, metrics-server-list
# =============================================================================

[[ -n "${_PVE_METRICS_LOADED:-}" ]] && return 0
readonly _PVE_METRICS_LOADED=1

action_metrics_server_create() {
  require_setting "METRICS_ID"   "Metrics server identifier"
  require_setting "METRICS_TYPE" "Type (influxdb or graphite)"
  require_setting "METRICS_HOST" "Server hostname/IP"
  require_setting "METRICS_PORT" "Server port"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local mid="${PLUGIN_METRICS_ID}"
  local mtype="${PLUGIN_METRICS_TYPE}"
  local host="${PLUGIN_METRICS_HOST}"
  local port="${PLUGIN_METRICS_PORT}"
  local token="${PLUGIN_METRICS_TOKEN:-}"
  local bucket="${PLUGIN_METRICS_BUCKET:-}"
  local org="${PLUGIN_METRICS_ORG:-}"

  local args=(-d "id=${mid}" -d "type=${mtype}" -d "server=${host}" -d "port=${port}")
  [[ -n "$token" ]]  && args+=(-d "token=${token}")
  [[ -n "$bucket" ]] && args+=(-d "bucket=${bucket}")
  [[ -n "$org" ]]    && args+=(-d "organization=${org}")

  pve_post "/cluster/metrics/server/${mid}" "${args[@]}" >/dev/null
  log_info "Metrics server '${mid}' (${mtype}) created -> ${host}:${port}"
}

action_metrics_server_list() {
  local result
  result=$(pve_get "/cluster/metrics/server")

  echo "$result" | jq -r '
    ["ID","TYPE","SERVER","PORT","DISABLE"],
    (.data[] | [
      .id,
      .type,
      (.server // "-"),
      (.port // "-" | tostring),
      (if .disable == 1 then "yes" else "no" end)
    ]) | @tsv' | column -t

  output_json "$(echo "$result" | jq '.data')"
  log_info "Found $(echo "$result" | jq '.data | length') metrics server(s)"
}
