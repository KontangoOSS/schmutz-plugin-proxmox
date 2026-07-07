#!/usr/bin/env bash
# =============================================================================
# pve-access.sh — User, token, and ACL management
# =============================================================================
# Actions: user-list, user-create, token-create, token-list, acl-set, acl-list,
#          role-list
# =============================================================================

[[ -n "${_PVE_ACCESS_LOADED:-}" ]] && return 0
readonly _PVE_ACCESS_LOADED=1

action_user_list() {
  local result
  result=$(pve_get "/access/users")

  echo "$result" | jq -r '
    ["USERID","EMAIL","ENABLE","REALM","EXPIRE","COMMENT"],
    (.data[] | [
      .userid,
      (.email // "-"),
      (if .enable == 1 then "yes" else "no" end),
      (.realm // "-"),
      (if .expire and .expire > 0 then (.expire | todate) else "never" end),
      (.comment // "-" | .[0:30])
    ]) | @tsv' | column -t

  local count
  count=$(echo "$result" | jq '.data | length')
  output_var "USER_COUNT" "$count"
  output_json "$(echo "$result" | jq '.data')"
  log_info "Found ${count} user(s)"
}

action_user_create() {
  require_setting "USERID"   "User ID (user@realm)"
  require_setting "PASSWORD" "User password"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local userid="${PLUGIN_USERID}"
  local password="${PLUGIN_PASSWORD}"
  local email="${PLUGIN_EMAIL:-}"
  local comment="${PLUGIN_COMMENT:-}"
  local groups="${PLUGIN_GROUPS:-}"
  local enable="${PLUGIN_ENABLE:-1}"
  local expire="${PLUGIN_EXPIRE:-0}"

  local args=(-d "userid=${userid}" -d "password=${password}" -d "enable=${enable}")
  [[ -n "$email" ]]   && args+=(-d "email=${email}")
  [[ -n "$comment" ]] && args+=(--data-urlencode "comment=${comment}")
  [[ -n "$groups" ]]  && args+=(-d "groups=${groups}")
  [[ "$expire" != "0" ]] && args+=(-d "expire=${expire}")

  pve_post "/access/users" "${args[@]}" >/dev/null
  output_var "PROXMOX_USERID" "$userid"
  log_info "User '${userid}' created"
}

action_token_create() {
  require_setting "USERID"   "User ID (user@realm)"
  require_setting "TOKEN_ID" "Token name"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local userid="${PLUGIN_USERID}"
  local tokenid="${PLUGIN_TOKEN_ID}"
  local privsep="${PLUGIN_PRIVSEP:-true}"
  local comment="${PLUGIN_COMMENT:-}"
  local expire="${PLUGIN_EXPIRE:-0}"

  local args=()
  [[ "$privsep" == "true" ]]  && args+=(-d "privsep=1") || args+=(-d "privsep=0")
  [[ -n "$comment" ]]         && args+=(--data-urlencode "comment=${comment}")
  [[ "$expire" != "0" ]]      && args+=(-d "expire=${expire}")

  local result
  result=$(pve_post "/access/users/${userid}/token/${tokenid}" "${args[@]}")

  local token_value
  token_value=$(echo "$result" | jq -r '.data.value // empty')

  if [[ -n "$token_value" ]]; then
    output_var "PROXMOX_TOKEN" "${userid}!${tokenid}=${token_value}"
    output_var "PROXMOX_TOKEN_VALUE" "$token_value"
    # Do NOT log the secret — CI logs are often visible to anyone with repo
    # read. The value is available to later steps via the PROXMOX_TOKEN output.
    log_info "Token '${tokenid}' created for ${userid} (value written to PROXMOX_TOKEN output)"
  else
    echo "$result" | jq '.data'
    log_warn "Token created but no value returned (may already exist)"
  fi
}

action_token_list() {
  require_setting "USERID" "User ID (user@realm)"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local userid="${PLUGIN_USERID}"
  local result
  result=$(pve_get "/access/users/${userid}/token")

  echo "$result" | jq -r '
    ["TOKEN","PRIVSEP","EXPIRE","COMMENT"],
    (.data[] | [
      .tokenid,
      (if .privsep == 1 then "yes" else "no" end),
      (if .expire and .expire > 0 then (.expire | todate) else "never" end),
      (.comment // "-")
    ]) | @tsv' | column -t

  output_json "$(echo "$result" | jq '.data')"
}

action_acl_set() {
  require_setting "ACL_PATH" "ACL path (e.g. /vms/100, /storage/local)"
  require_setting "ROLE"     "Role name (e.g. PVEAdmin, PVEVMUser)"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local acl_path="${PLUGIN_ACL_PATH}"
  local roles="${PLUGIN_ROLE}"
  local users="${PLUGIN_USERS:-}"
  local groups="${PLUGIN_GROUPS:-}"
  local propagate="${PLUGIN_PROPAGATE:-1}"

  local args=(--data-urlencode "path=${acl_path}" -d "roles=${roles}" -d "propagate=${propagate}")
  [[ -n "$users" ]]  && args+=(-d "users=${users}")
  [[ -n "$groups" ]] && args+=(-d "groups=${groups}")

  pve_put "/access/acl" "${args[@]}" >/dev/null
  log_info "ACL set: ${roles} on ${acl_path}"
}

action_acl_list() {
  local result
  result=$(pve_get "/access/acl")

  echo "$result" | jq -r '
    ["PATH","ROLEID","UGID","TYPE","PROPAGATE"],
    (.data[] | [
      .path,
      .roleid,
      .ugid,
      .type,
      (if .propagate == 1 then "yes" else "no" end)
    ]) | @tsv' | column -t

  output_json "$(echo "$result" | jq '.data')"
}

action_role_list() {
  local result
  result=$(pve_get "/access/roles")

  echo "$result" | jq -r '
    ["ROLEID","PRIVS","SPECIAL"],
    (.data[] | [
      .roleid,
      (.privs // "-" | .[0:60]),
      (if .special == 1 then "built-in" else "custom" end)
    ]) | @tsv' | column -t

  output_json "$(echo "$result" | jq '.data')"
}
