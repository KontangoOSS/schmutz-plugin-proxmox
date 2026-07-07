#!/usr/bin/env bash
# =============================================================================
# plugin-core.sh — Woodpecker CI Plugin Core Library
# =============================================================================
# Source this from your plugin.sh. Provides logging, validation, HTTP helpers
# with retry, auth abstraction, output, and action dispatch.
# =============================================================================

set -euo pipefail

[[ -n "${_PLUGIN_CORE_LOADED:-}" ]] && return 0
readonly _PLUGIN_CORE_LOADED=1

PLUGIN_CORE_VERSION="1.0.0"

# ── Exit codes ───────────────────────────────────────────────────────────
readonly EXIT_OK=0
readonly EXIT_SETTINGS=1
readonly EXIT_AUTH=2
readonly EXIT_API=3
readonly EXIT_ACTION=4
readonly EXIT_INTERNAL=5

# ── Color support ────────────────────────────────────────────────────────
if [[ -t 2 ]] && [[ "${TERM:-}" != "dumb" ]]; then
  _C_RED='\033[0;31m'; _C_YEL='\033[1;33m'; _C_BLU='\033[0;34m'
  _C_DIM='\033[2m'; _C_NC='\033[0m'
else
  _C_RED=''; _C_YEL=''; _C_BLU=''; _C_DIM=''; _C_NC=''
fi

# ── Logging ──────────────────────────────────────────────────────────────
_log() {
  local level="$1" color="$2"; shift 2
  local ts; ts=$(date -u +%H:%M:%S)
  echo -e "${color}[${ts}] [${level}]${_C_NC} $*" >&2
}
log_info()  { _log "INFO"  "$_C_BLU" "$@"; }
log_warn()  { _log "WARN"  "$_C_YEL" "$@"; }
log_error() { _log "ERROR" "$_C_RED" "$@"; }
log_debug() { [[ "${PLUGIN_DEBUG:-}" == "true" ]] && _log "DEBUG" "$_C_DIM" "$@" || true; }
log_fatal() { log_error "$@"; exit $EXIT_SETTINGS; }

# ── Settings validation ─────────────────────────────────────────────────
_VALIDATION_FAILED=0

require_setting() {
  local name="$1" desc="${2:-}"
  local var="PLUGIN_${name}"
  if [[ -z "${!var:-}" ]]; then
    log_error "Required setting '${name,,}' is not set${desc:+ — $desc}"
    _VALIDATION_FAILED=1
  fi
}

optional_setting() {
  local name="$1" default="$2"
  local var="PLUGIN_${name}"
  if [[ -z "${!var:-}" ]]; then
    eval "export ${var}='${default}'"
    log_debug "Setting '${name,,}' defaulted to '${default}'"
  fi
}

check_settings() {
  if declare -f settings_schema >/dev/null 2>&1; then
    settings_schema
  fi
  if [[ $_VALIDATION_FAILED -ne 0 ]]; then
    log_fatal "Settings validation failed"
  fi
}

# ── Auth abstraction ─────────────────────────────────────────────────────
_AUTH_HEADER=""

setup_auth() {
  local mode="${PLUGIN_AUTH_MODE:-none}"
  case "$mode" in
    bearer)
      [[ -z "${PLUGIN_TOKEN:-}" ]] && log_fatal "auth_mode=bearer requires 'token' setting"
      _AUTH_HEADER="Authorization: Bearer ${PLUGIN_TOKEN}"
      ;;
    api_key)
      [[ -z "${PLUGIN_API_KEY:-}" ]] && log_fatal "auth_mode=api_key requires 'api_key' setting"
      _AUTH_HEADER="${PLUGIN_API_KEY_HEADER:-X-API-Key}: ${PLUGIN_API_KEY}"
      ;;
    basic)
      [[ -z "${PLUGIN_USERNAME:-}" || -z "${PLUGIN_PASSWORD:-}" ]] && \
        log_fatal "auth_mode=basic requires 'username' and 'password' settings"
      local encoded; encoded=$(printf '%s:%s' "$PLUGIN_USERNAME" "$PLUGIN_PASSWORD" | base64 -w0)
      _AUTH_HEADER="Authorization: Basic ${encoded}"
      ;;
    pve)
      [[ -z "${PLUGIN_API_TOKEN:-}" ]] && log_fatal "auth_mode=pve requires 'api_token' setting"
      _AUTH_HEADER="Authorization: PVEAPIToken=${PLUGIN_API_TOKEN}"
      ;;
    none) _AUTH_HEADER="" ;;
    *) log_fatal "Unknown auth_mode: ${mode}" ;;
  esac
  [[ -n "$_AUTH_HEADER" ]] && log_info "Auth: ${mode}" || true
}

# ── HTTP helpers ─────────────────────────────────────────────────────────
http_request() {
  local method="$1" url="$2"; shift 2
  local max_retries="${PLUGIN_RETRY_MAX:-3}"
  local retry_delay="${PLUGIN_RETRY_DELAY:-2}"
  local timeout="${PLUGIN_HTTP_TIMEOUT:-30}"
  local attempt=1 raw http_code body
  local skip_tls="${PLUGIN_SKIP_VERIFY:-false}"

  local curl_args=(-s --connect-timeout "$timeout" -w '\n%{http_code}')
  [[ "$skip_tls" == "true" ]] && curl_args+=(-k)
  [[ -n "$_AUTH_HEADER" ]] && curl_args+=(-H "$_AUTH_HEADER")
  curl_args+=(-X "$method" "$@" "$url")

  while [[ $attempt -le $max_retries ]]; do
    log_debug "HTTP ${method} ${url} (attempt ${attempt}/${max_retries})"
    if raw=$(curl "${curl_args[@]}" 2>&1); then
      http_code=$(echo "$raw" | tail -1)
      body=$(echo "$raw" | sed '$d')
      if [[ "${http_code}" =~ ^2 ]]; then
        echo "$body"
        return 0
      fi
      log_warn "HTTP ${http_code} from ${method} ${url}"
      # 429 (rate-limited) and 5xx are transient — fall through to retry.
      # Other 4xx are the client's fault (bad request/auth/not-found) — fail fast.
      if [[ "${http_code}" =~ ^4[0-9][0-9]$ && "${http_code}" != "429" ]]; then
        log_error "Client error ${http_code}: ${body}"
        return 1
      fi
    else
      log_warn "HTTP ${method} ${url} failed (attempt ${attempt})"
    fi
    [[ $attempt -lt $max_retries ]] && sleep "$retry_delay"
    attempt=$((attempt + 1))
  done
  log_error "HTTP ${method} ${url} failed after ${max_retries} attempts"
  return 1
}

http_get()    { http_request GET    "$@"; }
http_post()   { http_request POST   "$@"; }
http_put()    { http_request PUT    "$@"; }
http_delete() { http_request DELETE "$@"; }

# ── Output helpers ───────────────────────────────────────────────────────
output_var() {
  local key="$1" value="$2"
  local f="${PLUGIN_OUTPUT_FILE:-.env}"
  # Escape single quotes so a value containing one can't break the generated
  # .env line or inject shell: ' -> '\'' inside the single-quoted string.
  local escaped="${value//\'/\'\\\'\'}"
  echo "export ${key}='${escaped}'" >> "$f"
  log_debug "Output: ${key}=<set>"
}

output_json() {
  local json="$1"
  local f="${PLUGIN_OUTPUT_JSON_FILE:-output.json}"
  echo "$json" > "$f"
  log_debug "JSON written to ${f}"
}

# ── Action dispatch ──────────────────────────────────────────────────────
dispatch_action() {
  local action="${PLUGIN_ACTION:-}"
  [[ -z "$action" ]] && log_fatal "Required setting 'action' is not set"

  local fn="action_${action//-/_}"
  if declare -f "$fn" >/dev/null 2>&1; then
    log_info "Action: ${action}"
    "$fn"
    log_info "Done: ${action}"
  else
    local avail; avail=$(declare -F | awk '/action_/{sub(/.*action_/,""); printf "%s ", $0}')
    log_error "Unknown action '${action}'. Available: ${avail:-none}"
    exit $EXIT_ACTION
  fi
}

# ── Entrypoint ───────────────────────────────────────────────────────────
show_version() {
  echo "${PLUGIN_NAME:-plugin} v${PLUGIN_VERSION:-0.0.0} (core: ${PLUGIN_CORE_VERSION})"
}

plugin_run() {
  case "${1:-}" in
    --help|-h)    show_version; echo "Actions:"; declare -F | awk '/action_/{sub(/.*action_/,"  "); print}'; exit 0 ;;
    --version|-v) show_version; exit 0 ;;
  esac

  log_info "$(show_version)"
  check_settings
  setup_auth
  dispatch_action
}
