#!/usr/bin/env bash
# =============================================================================
# pve-api.sh — Proxmox VE API helpers
# =============================================================================
# Wraps plugin-core HTTP functions with Proxmox-specific behavior:
#   - PVEAPIToken auth header
#   - Response unwrapping (.data extraction)
#   - Form-encoded POST/PUT (Proxmox doesn't use JSON for writes)
#   - Async task (UPID) polling
# =============================================================================

[[ -n "${_PVE_API_LOADED:-}" ]] && return 0
readonly _PVE_API_LOADED=1

# ── API base ────────────────────────────────────────────────────────────

_pve_url() {
  echo "${PLUGIN_API_URL}/api2/json${1}"
}

# ── Core request ────────────────────────────────────────────────────────
# Returns raw JSON from Proxmox (including the .data wrapper).
# Caller can pipe through jq as needed.

pve_get() {
  http_get "$(_pve_url "$1")"
}

pve_post() {
  local path="$1"; shift
  http_post "$(_pve_url "$path")" "$@"
}

pve_put() {
  local path="$1"; shift
  http_put "$(_pve_url "$path")" "$@"
}

pve_delete() {
  http_delete "$(_pve_url "$1")"
}

# ── Data extraction ─────────────────────────────────────────────────────
# Proxmox wraps responses in {"data": ...}. These helpers unwrap it.

pve_data() {
  # Pipe JSON through this: pve_get "/path" | pve_data
  jq -r '.data'
}

pve_field() {
  # Extract a single field: pve_get "/path" | pve_field "status"
  local field="$1"
  jq -r ".data.${field} // empty"
}

# ── Task polling ────────────────────────────────────────────────────────
# Proxmox async operations return a UPID string. Poll until done.

wait_for_task() {
  local upid="$1"
  local timeout="${2:-${PLUGIN_TIMEOUT:-120}}"
  local interval="${3:-3}"
  local node="${PLUGIN_NODE}"
  local elapsed=0

  log_info "Waiting for task: ${upid##*:}"

  while [[ $elapsed -lt $timeout ]]; do
    local result status
    result=$(pve_get "/nodes/${node}/tasks/${upid}/status")
    status=$(echo "$result" | jq -r '.data.status')

    if [[ "$status" == "stopped" ]]; then
      local exitstatus
      exitstatus=$(echo "$result" | jq -r '.data.exitstatus')
      if [[ "$exitstatus" == "OK" ]]; then
        log_info "Task completed"
        return 0
      else
        log_error "Task failed: ${exitstatus}"
        # Dump task log for debugging
        pve_get "/nodes/${node}/tasks/${upid}/log" \
          | jq -r '.data[]?.t // empty' 2>/dev/null || true
        return 1
      fi
    fi

    log_debug "Task poll (${elapsed}s): ${status}"
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  log_error "Task timed out after ${timeout}s"
  return 1
}

# ── Task extraction helper ──────────────────────────────────────────────
# POST actions return {"data": "UPID:..."}. Extract and poll.

pve_post_task() {
  local path="$1"; shift
  local result upid

  result=$(pve_post "$path" "$@")
  upid=$(echo "$result" | jq -r '.data // empty')

  if [[ -z "$upid" || "$upid" == "null" ]]; then
    local msg
    msg=$(echo "$result" | jq -r '.message // .errors // "unknown error"')
    log_error "API call failed: ${msg}"
    return 1
  fi

  wait_for_task "$upid"
}

# ── VMID helpers ────────────────────────────────────────────────────────

find_next_vmid() {
  local result
  result=$(pve_get "/cluster/nextid")
  local vmid
  vmid=$(echo "$result" | jq -r '.data')
  if [[ -z "$vmid" || "$vmid" == "null" ]]; then
    log_error "Failed to get next VMID from cluster"
    return 1
  fi
  echo "$vmid"
}

# ── ISO existence check ─────────────────────────────────────────────────
# Given an ISO volid (e.g. "local:iso/debian-12.iso"), confirm it is present
# in its storage on the target node. Returns 0 if found, 1 otherwise.

pve_iso_exists() {
  local volid="$1"
  local node="${PLUGIN_NODE}"
  local storage="${volid%%:*}"

  [[ -z "$storage" || "$storage" == "$volid" ]] && return 1

  pve_get "/nodes/${node}/storage/${storage}/content?content=iso" 2>/dev/null \
    | jq -e --arg v "$volid" '.data[]? | select(.volid == $v)' >/dev/null 2>&1
}

# ── Convenience: get container/VM IP ────────────────────────────────────

get_guest_ip() {
  local vmid="$1"
  local node="${PLUGIN_NODE}"
  local retries="${2:-20}"
  local delay="${3:-3}"
  local attempt=1 ip=""

  while [[ $attempt -le $retries ]]; do
    local result
    result=$(pve_get "/nodes/${node}/lxc/${vmid}/interfaces" 2>/dev/null || echo "")
    if [[ -n "$result" ]]; then
      ip=$(echo "$result" | jq -r \
        '[.data[]? | select(.name != "lo") | .["inet-address"]? // empty] | first // empty' \
        2>/dev/null || echo "")
    fi
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
    log_debug "Waiting for IP (attempt ${attempt}/${retries})"
    sleep "$delay"
    attempt=$((attempt + 1))
  done

  log_warn "No IP found for VMID ${vmid} after ${retries} attempts"
  return 1
}
