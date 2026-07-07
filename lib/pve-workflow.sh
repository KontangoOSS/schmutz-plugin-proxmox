#!/usr/bin/env bash
# =============================================================================
# pve-workflow.sh — Ansible workflow actions
# =============================================================================
# Routes workflow actions to Ansible playbooks shipped in /plugin/ansible/
# Actions: workflow-provision, workflow-deploy, workflow-safe-deploy,
#          workflow-clone, workflow-teardown, ansible-run
# =============================================================================

[[ -n "${_PVE_WORKFLOW_LOADED:-}" ]] && return 0
readonly _PVE_WORKFLOW_LOADED=1

ANSIBLE_DIR="${SCRIPT_DIR}/ansible"

_run_playbook() {
  local playbook="$1"; shift
  local pb_path="${ANSIBLE_DIR}/playbooks/${playbook}"

  if [[ ! -f "$pb_path" ]]; then
    log_error "Playbook not found: ${playbook}"
    return 1
  fi

  local args=()
  args+=(-e "proxmox_api_url=${PLUGIN_API_URL}")
  args+=(-e "proxmox_api_token=${PLUGIN_API_TOKEN}")
  args+=(-e "proxmox_node=${PLUGIN_NODE}")

  # Pass any additional extra-vars
  "$@"  # no-op, extra args passed via the caller

  log_info "Running playbook: ${playbook}"
  log_debug "ansible-playbook ${pb_path} ${args[*]} $*"

  ANSIBLE_CONFIG="${ANSIBLE_DIR}/ansible.cfg" \
    ansible-playbook "$pb_path" "${args[@]}" "$@"
}

action_workflow_provision() {
  local extra=()
  [[ -n "${PLUGIN_VMID:-}" ]]           && extra+=(-e "vmid=${PLUGIN_VMID}")
  [[ -n "${PLUGIN_HOSTNAME:-}" ]]       && extra+=(-e "hostname=${PLUGIN_HOSTNAME}")
  [[ -n "${PLUGIN_GUEST_TYPE:-}" ]]     && extra+=(-e "guest_type=${PLUGIN_GUEST_TYPE}")
  [[ -n "${PLUGIN_MEMORY:-}" ]]         && extra+=(-e "memory=${PLUGIN_MEMORY}")
  [[ -n "${PLUGIN_CORES:-}" ]]          && extra+=(-e "cores=${PLUGIN_CORES}")
  [[ -n "${PLUGIN_STORAGE:-}" ]]        && extra+=(-e "storage=${PLUGIN_STORAGE}")
  [[ -n "${PLUGIN_CONFIGURE_ROLES:-}" ]] && extra+=(-e "configure_roles=${PLUGIN_CONFIGURE_ROLES}")

  _run_playbook "provision-and-configure.yml" "${extra[@]}"
}

action_workflow_deploy() {
  local extra=()
  [[ -n "${PLUGIN_APP_NAME:-}" ]]          && extra+=(-e "app_name=${PLUGIN_APP_NAME}")
  [[ -n "${PLUGIN_APP_DEPLOY_METHOD:-}" ]] && extra+=(-e "app_deploy_method=${PLUGIN_APP_DEPLOY_METHOD}")
  [[ -n "${PLUGIN_APP_DOCKER_IMAGE:-}" ]]  && extra+=(-e "app_docker_image=${PLUGIN_APP_DOCKER_IMAGE}")
  [[ -n "${PLUGIN_APP_DOCKER_TAG:-}" ]]    && extra+=(-e "app_docker_tag=${PLUGIN_APP_DOCKER_TAG}")
  [[ -n "${PLUGIN_TARGET_HOSTS:-}" ]]      && extra+=(-e "target_hosts=${PLUGIN_TARGET_HOSTS}")

  local inv_args=()
  if [[ -n "${PLUGIN_INVENTORY:-}" ]]; then
    inv_args+=(-i "${PLUGIN_INVENTORY}")
  fi

  _run_playbook "deploy-app.yml" "${inv_args[@]}" "${extra[@]}"
}

action_workflow_safe_deploy() {
  require_setting "VMID" "VM/CT ID to snapshot and deploy to"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local extra=()
  extra+=(-e "vmid=${PLUGIN_VMID}")
  [[ -n "${PLUGIN_APP_NAME:-}" ]]          && extra+=(-e "app_name=${PLUGIN_APP_NAME}")
  [[ -n "${PLUGIN_APP_DEPLOY_METHOD:-}" ]] && extra+=(-e "app_deploy_method=${PLUGIN_APP_DEPLOY_METHOD}")
  [[ -n "${PLUGIN_TARGET_HOSTS:-}" ]]      && extra+=(-e "target_hosts=${PLUGIN_TARGET_HOSTS}")

  local inv_args=()
  if [[ -n "${PLUGIN_INVENTORY:-}" ]]; then
    inv_args+=(-i "${PLUGIN_INVENTORY}")
  fi

  _run_playbook "safe-deploy.yml" "${inv_args[@]}" "${extra[@]}"
}

action_workflow_clone() {
  require_setting "VMID" "Source VM/CT ID to clone"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local extra=()
  extra+=(-e "source_vmid=${PLUGIN_VMID}")
  [[ -n "${PLUGIN_CLONE_NAME:-}" ]]        && extra+=(-e "clone_name=${PLUGIN_CLONE_NAME}")
  [[ -n "${PLUGIN_CLONE_VMID:-}" ]]        && extra+=(-e "clone_vmid=${PLUGIN_CLONE_VMID}")
  [[ -n "${PLUGIN_TARGET_NODE:-}" ]]       && extra+=(-e "target_node=${PLUGIN_TARGET_NODE}")
  [[ -n "${PLUGIN_TARGET_STORAGE:-}" ]]    && extra+=(-e "target_storage=${PLUGIN_TARGET_STORAGE}")
  [[ -n "${PLUGIN_CONFIGURE_ROLES:-}" ]]   && extra+=(-e "configure_roles=${PLUGIN_CONFIGURE_ROLES}")

  _run_playbook "clone-environment.yml" "${extra[@]}"
}

action_workflow_teardown() {
  require_setting "VMIDS" "Comma-separated VM/CT IDs to destroy"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local extra=()
  extra+=(-e "vmids=${PLUGIN_VMIDS}")
  [[ "${PLUGIN_SNAPSHOT_BEFORE:-false}" == "true" ]] && extra+=(-e "create_snapshot_before=true")

  _run_playbook "teardown.yml" "${extra[@]}"
}

action_ansible_run() {
  require_setting "PLAYBOOK" "Path to Ansible playbook"
  [[ $_VALIDATION_FAILED -ne 0 ]] && log_fatal "Missing required settings"

  local playbook="${PLUGIN_PLAYBOOK}"
  local extra=()

  extra+=(-e "proxmox_api_url=${PLUGIN_API_URL}")
  extra+=(-e "proxmox_api_token=${PLUGIN_API_TOKEN}")
  extra+=(-e "proxmox_node=${PLUGIN_NODE}")
  [[ -n "${PLUGIN_EXTRA_VARS:-}" ]] && extra+=(-e "${PLUGIN_EXTRA_VARS}")

  local inv_args=()
  [[ -n "${PLUGIN_INVENTORY:-}" ]] && inv_args+=(-i "${PLUGIN_INVENTORY}")

  log_info "Running custom playbook: ${playbook}"
  ANSIBLE_CONFIG="${ANSIBLE_DIR}/ansible.cfg" \
    ansible-playbook "$playbook" "${inv_args[@]}" "${extra[@]}"
}
