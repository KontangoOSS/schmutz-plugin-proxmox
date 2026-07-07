#!/usr/bin/env bash
# =============================================================================
# test.sh — Local test runner for the Proxmox plugin
# =============================================================================
# Usage:
#   ./test.sh action=lxc-list api_url=https://pve:8006 api_token=user@pam!id=secret node=pve
#   ./test.sh action=node-status   # uses env vars if set
#
# Settings can be passed as key=value args or as PLUGIN_* env vars.
# =============================================================================

set -euo pipefail

IMAGE="${PLUGIN_TEST_IMAGE:-proxmox-plugin}"

# Build image if needed
if ! docker image inspect "$IMAGE" &>/dev/null; then
  echo "Building image..."
  docker build -t "$IMAGE" "$(dirname "$0")" || exit 1
fi

# Collect env vars
env_args=()

# Pass through existing PLUGIN_* vars from environment
while IFS='=' read -r key val; do
  [[ "$key" == PLUGIN_* ]] && env_args+=(-e "$key=$val")
done < <(env)

# Parse key=value arguments and convert to PLUGIN_* env vars
for arg in "$@"; do
  if [[ "$arg" == *=* ]]; then
    key="${arg%%=*}"
    val="${arg#*=}"
    key="PLUGIN_$(echo "$key" | tr '[:lower:]-' '[:upper:]_')"
    env_args+=(-e "$key=$val")
  fi
done

# Defaults
[[ ! " ${env_args[*]} " =~ "PLUGIN_AUTH_MODE" ]]   && env_args+=(-e "PLUGIN_AUTH_MODE=pve")
[[ ! " ${env_args[*]} " =~ "PLUGIN_SKIP_VERIFY" ]] && env_args+=(-e "PLUGIN_SKIP_VERIFY=true")
[[ ! " ${env_args[*]} " =~ "PLUGIN_DEBUG" ]]       && env_args+=(-e "PLUGIN_DEBUG=true")

echo "Running: docker run --rm ${env_args[*]} $IMAGE"
echo "---"
docker run --rm "${env_args[@]}" "$IMAGE"
