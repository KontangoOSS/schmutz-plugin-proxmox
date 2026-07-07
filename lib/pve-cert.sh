#!/usr/bin/env bash
# =============================================================================
# pve-cert.sh — TLS certificate management
# =============================================================================
# Actions: cert-list, cert-upload, acme-setup
# =============================================================================

[[ -n "${_PVE_CERT_LOADED:-}" ]] && return 0
readonly _PVE_CERT_LOADED=1

action_cert_list() {
  local node="${PLUGIN_NODE}"
  local result
  result=$(pve_get "/nodes/${node}/certificates/info")

  echo "$result" | jq -r '
    ["FILENAME","SUBJECT","ISSUER","NOTAFTER","FP"],
    (.data[] | [
      (.filename // "-"),
      (.subject // "-" | .[0:30]),
      (.issuer // "-" | .[0:30]),
      (if .notafter then (.notafter | todate) else "-" end),
      (.fingerprint // "-" | .[0:20])
    ]) | @tsv' | column -t

  output_json "$(echo "$result" | jq '.data')"
  log_info "Certificate info retrieved"
}

action_cert_upload() {
  require_setting "CERT"    "PEM certificate content or file path"
  require_setting "KEY"     "PEM private key content or file path"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local node="${PLUGIN_NODE}"
  local cert="${PLUGIN_CERT}"
  local key="${PLUGIN_KEY}"
  local force="${PLUGIN_FORCE:-false}"
  local restart="${PLUGIN_RESTART:-true}"

  local args=(--data-urlencode "certificates=${cert}" --data-urlencode "key=${key}")
  [[ "$force" == "true" ]]   && args+=(-d "force=1")
  [[ "$restart" == "true" ]] && args+=(-d "restart=1")

  pve_post "/nodes/${node}/certificates/custom" "${args[@]}" >/dev/null
  log_info "Custom certificate uploaded to node ${node}"
}

action_acme_setup() {
  local node="${PLUGIN_NODE}"
  local domains="${PLUGIN_ACME_DOMAINS:-}"
  local account="${PLUGIN_ACME_ACCOUNT:-default}"

  if [[ -n "$domains" ]]; then
    log_info "Configuring ACME domains: ${domains}"
    pve_put "/nodes/${node}/config" \
      --data-urlencode "acmedomain0=${domains}" \
      -d "acme=account=${account}"
  fi

  log_info "Ordering ACME certificate..."
  pve_post_task "/nodes/${node}/certificates/acme/certificate"
  log_info "ACME certificate issued"
}
