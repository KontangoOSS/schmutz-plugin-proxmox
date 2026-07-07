#!/usr/bin/env bash
# =============================================================================
# pve-exec.sh — Execute commands inside Proxmox containers
# =============================================================================
# Runs commands inside LXC containers by SSHing to the Proxmox host
# and using `pct exec`. Supports password and key-based SSH auth.
# =============================================================================

[[ -n "${_PVE_EXEC_LOADED:-}" ]] && return 0
readonly _PVE_EXEC_LOADED=1

# ── SSH config ──────────────────────────────────────────────────────────

_pve_ssh_host() {
  local host="${PLUGIN_SSH_HOST:-}"
  if [[ -z "$host" ]]; then
    # Derive from API URL: https://pve.example.com:8006 -> pve.example.com
    host=$(echo "${PLUGIN_API_URL}" | sed 's|https\?://||; s|:.*||')
  fi
  echo "$host"
}

_pve_ssh_opts() {
  echo "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
}

# ── Core exec ───────────────────────────────────────────────────────────
# Pushes a script into the container and executes it via pct exec.
# This avoids quoting hell with inline commands.

pve_exec() {
  local cmd="$1"
  local vmid="${PLUGIN_VMID}"
  local ssh_host ssh_user ssh_opts
  ssh_host=$(_pve_ssh_host)
  ssh_user="${PLUGIN_SSH_USER:-root}"
  ssh_opts=$(_pve_ssh_opts)

  log_debug "pct exec ${vmid} -- ${cmd:0:80}..."

  local remote_script="/tmp/pve-exec-$$.sh"
  local ssh_cmd="cat > $remote_script << 'PVEEOF'
#!/bin/bash
$cmd
PVEEOF
chmod +x $remote_script && pct push $vmid $remote_script /tmp/exec.sh && pct exec $vmid -- bash /tmp/exec.sh; rc=\$?; rm -f $remote_script; exit \$rc"

  if [[ -n "${PLUGIN_SSH_PASSWORD:-}" ]]; then
    sshpass -p "${PLUGIN_SSH_PASSWORD}" ssh $ssh_opts "${ssh_user}@${ssh_host}" "$ssh_cmd" 2>&1
  elif [[ -n "${PLUGIN_SSH_KEY:-}" ]]; then
    local keyfile
    keyfile=$(mktemp)
    echo "${PLUGIN_SSH_KEY}" > "$keyfile"
    chmod 600 "$keyfile"
    ssh $ssh_opts -i "$keyfile" "${ssh_user}@${ssh_host}" "$ssh_cmd" 2>&1
    rm -f "$keyfile"
  else
    log_error "pve_exec requires ssh_password or ssh_key setting"
    return 1
  fi
}

# ── Action: lxc-exec ────────────────────────────────────────────────────

action_lxc_exec() {
  require_setting "VMID"    "Container ID"
  require_setting "COMMAND" "Command to execute"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local cmd="${PLUGIN_COMMAND}"
  log_info "Executing in container ${PLUGIN_VMID}: ${cmd:0:80}"

  # `|| rc=$?` keeps set -e from aborting on a non-zero remote command, so we
  # can report the real exit code instead of a generic script abort.
  local output rc=0
  output=$(pve_exec "$cmd") || rc=$?

  echo "$output"
  output_var "EXEC_EXIT_CODE" "$rc"

  if [[ $rc -eq 0 ]]; then
    log_info "Command completed successfully"
  else
    log_error "Command exited with code ${rc}"
    return $rc
  fi
}

# ── Quiet exec (log on failure only) ────────────────────────────────────

pve_exec_quiet() {
  local cmd="$1"
  local output
  if output=$(pve_exec "$cmd" 2>&1); then
    log_debug "exec ok: ${cmd:0:60}"
    [[ -n "$output" ]] && log_debug "$output"
    return 0
  else
    log_error "exec failed: ${cmd:0:60}"
    [[ -n "$output" ]] && log_error "$output"
    return 1
  fi
}
