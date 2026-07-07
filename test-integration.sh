#!/usr/bin/env bash
# =============================================================================
# test-integration.sh — Live integration tests for the Proxmox plugin
# =============================================================================
# Exercises the real create/delete/resize/ISO/RBAC paths against a live
# Proxmox instance and asserts outcomes. Every guest it creates it destroys;
# a trap guarantees cleanup even on failure.
#
# Usage:
#   PLUGIN_API_URL=https://pve.example:8006 \
#   PLUGIN_API_TOKEN='user@realm!id=secret' \
#   PLUGIN_NODE=hank \
#   ./test-integration.sh
#
# Optional:
#   TEST_STORAGE   storage for rootfs/disk   (default: local-lvm)
#   TEST_TEMPLATE  LXC ostemplate volid       (default: debian-12 on local)
#   TEST_NODES     space-separated node list to run the multi-node create on
#                  (default: just PLUGIN_NODE)
#
# Exit code 0 = all passed, non-zero = failures.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="${SCRIPT_DIR}/plugin.sh"

: "${PLUGIN_API_URL:?set PLUGIN_API_URL}"
: "${PLUGIN_API_TOKEN:?set PLUGIN_API_TOKEN}"
: "${PLUGIN_NODE:?set PLUGIN_NODE}"
export PLUGIN_AUTH_MODE="${PLUGIN_AUTH_MODE:-pve}"
export PLUGIN_SKIP_VERIFY="${PLUGIN_SKIP_VERIFY:-true}"

TEST_STORAGE="${TEST_STORAGE:-local-lvm}"
TEST_TEMPLATE="${TEST_TEMPLATE:-local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst}"
TEST_NODES="${TEST_NODES:-$PLUGIN_NODE}"

API="${PLUGIN_API_URL}/api2/json"
AUTH="Authorization: PVEAPIToken=${PLUGIN_API_TOKEN}"

PASS=0; FAIL=0
CREATED_LXC=()   # "node:vmid"
CREATED_VM=()    # "node:vmid"

# ── helpers ──────────────────────────────────────────────────────────────
c_grn=$'\033[0;32m'; c_red=$'\033[0;31m'; c_dim=$'\033[2m'; c_nc=$'\033[0m'
ok()   { echo "  ${c_grn}✓${c_nc} $*"; PASS=$((PASS+1)); }
bad()  { echo "  ${c_red}✗${c_nc} $*"; FAIL=$((FAIL+1)); }
head() { echo; echo "── $* ──"; }

# Run the plugin with a set of PLUGIN_* overrides passed as KEY=VAL args.
# Runs the plugin in a subshell so per-call overrides never leak into the
# test's own environment (and never clobber the base PLUGIN_API_URL/NODE/etc).
# The plugin's output-var file is exposed to the caller as $RUN_OUTFILE.
RUN_OUTFILE=""
run() {
  RUN_OUTFILE=$(mktemp)
  local json_file; json_file=$(mktemp)
  (
    export PLUGIN_OUTPUT_FILE="$RUN_OUTFILE"
    export PLUGIN_OUTPUT_JSON_FILE="$json_file"
    local kv
    for kv in "$@"; do export "${kv?}"; done
    exec bash "$PLUGIN"
  ) 2>&1
}

# Extract an output var (e.g. PROXMOX_VMID) the plugin wrote during the last run().
run_var() { grep -E "^export $1=" "$RUN_OUTFILE" 2>/dev/null | tail -1 | sed -E "s/^export $1='(.*)'$/\1/"; }

api_get() { curl -sk --max-time 20 -H "$AUTH" "$API$1"; }
lxc_exists() { api_get "/nodes/$1/lxc/$2/status/current" | jq -e '.data.status' >/dev/null 2>&1; }
vm_exists()  { api_get "/nodes/$1/qemu/$2/status/current" | jq -e '.data.status' >/dev/null 2>&1; }

# Poll until a guest is gone (delete is async; the config unlinks slightly after
# the destroy call returns). Returns 0 if gone within the window, 1 otherwise.
wait_gone() {
  local kind="$1" node="$2" vmid="$3" i
  for i in $(seq 1 15); do
    if [[ "$kind" == lxc ]]; then lxc_exists "$node" "$vmid" || return 0
    else vm_exists "$node" "$vmid" || return 0; fi
    sleep 2
  done
  return 1
}
next_vmid()  { api_get "/cluster/nextid" | jq -r '.data'; }

cleanup() {
  head "CLEANUP"
  local entry node vmid
  for entry in "${CREATED_LXC[@]:-}"; do
    [[ -z "$entry" ]] && continue
    node="${entry%%:*}"; vmid="${entry##*:}"
    if lxc_exists "$node" "$vmid"; then
      echo "  destroying leftover LXC $node/$vmid"
      run PLUGIN_ACTION=lxc-destroy PLUGIN_NODE="$node" PLUGIN_VMID="$vmid" >/dev/null 2>&1
    fi
  done
  for entry in "${CREATED_VM[@]:-}"; do
    [[ -z "$entry" ]] && continue
    node="${entry%%:*}"; vmid="${entry##*:}"
    if vm_exists "$node" "$vmid"; then
      echo "  destroying leftover VM $node/$vmid"
      run PLUGIN_ACTION=vm-destroy PLUGIN_NODE="$node" PLUGIN_VMID="$vmid" >/dev/null 2>&1
    fi
  done
}
trap cleanup EXIT

# =============================================================================
# TEST 1 — connectivity + auth (node-list must succeed)
# =============================================================================
head "TEST 1: connectivity & auth"
NL_OUT=$(run PLUGIN_ACTION=node-list)
if grep -q "$PLUGIN_NODE" <<<"$NL_OUT"; then
  ok "node-list reached $PLUGIN_API_URL and listed node $PLUGIN_NODE"
else
  bad "node-list failed — cannot reach instance or auth rejected"
  echo "  (aborting: no point continuing without connectivity)"; exit 1
fi

# =============================================================================
# TEST 2 — RBAC: token must hold the privileges the plugin needs
# =============================================================================
head "TEST 2: RBAC / token privileges"
PERMS=$(api_get "/access/permissions" | jq -r '.data["/"] // .data["/vms"] // {} | keys[]' 2>/dev/null)
need=(VM.Allocate VM.Config.Disk VM.Config.Memory VM.PowerMgmt Datastore.AllocateSpace VM.Audit)
missing=()
for p in "${need[@]}"; do echo "$PERMS" | grep -qx "$p" || missing+=("$p"); done
if [[ ${#missing[@]} -eq 0 ]]; then
  ok "token holds all required provisioning privileges"
else
  bad "token missing privileges: ${missing[*]}"
fi
# Warn (not fail) if the token is root-admin / not privsep — security posture.
USER="${PLUGIN_API_TOKEN%%!*}"; TOK="${PLUGIN_API_TOKEN##*!}"; TOK="${TOK%%=*}"
PRIVSEP=$(api_get "/access/users/$USER/token/$TOK" | jq -r '.data.privsep // "?"')
if echo "$PERMS" | grep -qx "Permissions.Modify"; then
  echo "  ${c_dim}note: token has Permissions.Modify at '/' (root-admin, privsep=$PRIVSEP)."
  echo "        recommend a privsep=1 token scoped to Kontango.PlatformAdmin.${c_nc}"
fi

# =============================================================================
# TEST 3 — LXC create → verify sizing → resize → destroy (per node)
# =============================================================================
for NODE in $TEST_NODES; do
  head "TEST 3 [$NODE]: LXC create/verify/resize/destroy"
  run PLUGIN_ACTION=lxc-create PLUGIN_NODE="$NODE" \
      PLUGIN_HOSTNAME="citest-$NODE" PLUGIN_STORAGE="$TEST_STORAGE" \
      PLUGIN_OSTEMPLATE="$TEST_TEMPLATE" PLUGIN_CORES=2 PLUGIN_MEMORY=1024 \
      PLUGIN_ROOTFS_SIZE=4 PLUGIN_START_ON_CREATE=false >/dev/null
  # Read the VMID the plugin actually used (auto-assigned, race-safe).
  RVMID=$(run_var PROXMOX_VMID)
  if [[ -z "$RVMID" ]]; then bad "lxc-create produced no PROXMOX_VMID"; continue; fi
  CREATED_LXC+=("$NODE:$RVMID")

  if lxc_exists "$NODE" "$RVMID"; then
    ok "created LXC $RVMID on $NODE"
  else
    bad "LXC $RVMID not present on $NODE after create"; continue
  fi

  CFG=$(api_get "/nodes/$NODE/lxc/$RVMID/config")
  [[ "$(jq -r '.data.cores' <<<"$CFG")" == "2" ]]   && ok "cores=2 honored"   || bad "cores mismatch"
  [[ "$(jq -r '.data.memory' <<<"$CFG")" == "1024" ]] && ok "memory=1024 honored" || bad "memory mismatch"

  # Resize cpu/mem + disk increment (regression guard for the +G urlencode bug)
  run PLUGIN_ACTION=lxc-resize PLUGIN_NODE="$NODE" PLUGIN_VMID="$RVMID" \
      PLUGIN_CORES=3 PLUGIN_MEMORY=1536 PLUGIN_DISK="+1G" >/dev/null 2>&1
  CFG=$(api_get "/nodes/$NODE/lxc/$RVMID/config")
  [[ "$(jq -r '.data.cores' <<<"$CFG")" == "3" ]] && ok "resize cores→3" || bad "resize cores failed"
  if jq -r '.data.rootfs' <<<"$CFG" | grep -q "size=5G"; then
    ok "disk resize +1G applied (4→5G)"
  else
    bad "disk resize +1G NOT applied (rootfs: $(jq -r '.data.rootfs' <<<"$CFG"))"
  fi

  # Destroy → confirm no orphan (delete is async; poll for the guest to vanish)
  run PLUGIN_ACTION=lxc-destroy PLUGIN_NODE="$NODE" PLUGIN_VMID="$RVMID" >/dev/null 2>&1
  if wait_gone lxc "$NODE" "$RVMID"; then
    ok "destroyed cleanly, no orphan"
    CREATED_LXC=("${CREATED_LXC[@]/$NODE:$RVMID}")  # drop from cleanup list
  else
    bad "LXC $RVMID still present after destroy (ORPHAN)"
  fi
done

# =============================================================================
# TEST 4 — idempotent destroy (non-existent vmid must not error)
# =============================================================================
head "TEST 4: idempotent destroy"
ID_OUT=$(run PLUGIN_ACTION=lxc-destroy PLUGIN_NODE="$PLUGIN_NODE" PLUGIN_VMID=99987)
if grep -qi "does not exist" <<<"$ID_OUT"; then
  ok "destroying non-existent container is a clean no-op"
else
  bad "idempotent destroy did not report 'does not exist'"
fi

# =============================================================================
# TEST 5 — VM ISO precheck: bogus ISO must fail BEFORE creating anything
# =============================================================================
head "TEST 5: VM create ISO precheck (negative)"
NVMID=$(next_vmid)
OUT=$(run PLUGIN_ACTION=vm-create PLUGIN_NODE="$PLUGIN_NODE" PLUGIN_VMID="$NVMID" \
      PLUGIN_VM_NAME="citest-isoneg" PLUGIN_STORAGE="$TEST_STORAGE" \
      PLUGIN_DISK_SIZE=8 PLUGIN_ISO="local:iso/__nope__.iso")
if grep -qi "ISO not found" <<<"$OUT" && ! vm_exists "$PLUGIN_NODE" "$NVMID"; then
  ok "missing ISO rejected early; no VM created"
else
  bad "ISO precheck failed to guard (VM may have been created)"
  vm_exists "$PLUGIN_NODE" "$NVMID" && CREATED_VM+=("$PLUGIN_NODE:$NVMID")
fi

# =============================================================================
# TEST 6 — VM create with a REAL ISO + pinned MAC → verify → destroy
# =============================================================================
head "TEST 6: VM create (real ISO + MAC)"
REAL_ISO=$(api_get "/nodes/$PLUGIN_NODE/storage/local/content?content=iso" \
           | jq -r '.data[0].volid // empty')
if [[ -z "$REAL_ISO" ]]; then
  echo "  ${c_dim}skipped: no ISO available on $PLUGIN_NODE/local${c_nc}"
else
  NVMID=$(next_vmid)
  MAC="BC:24:11:AA:BB:C0"
  run PLUGIN_ACTION=vm-create PLUGIN_NODE="$PLUGIN_NODE" PLUGIN_VMID="$NVMID" \
      PLUGIN_VM_NAME="citest-vm" PLUGIN_STORAGE="$TEST_STORAGE" PLUGIN_DISK_SIZE=8 \
      PLUGIN_ISO="$REAL_ISO" PLUGIN_MAC="$MAC" PLUGIN_START_ON_CREATE=false >/dev/null 2>&1
  CREATED_VM+=("$PLUGIN_NODE:$NVMID")
  CFG=$(api_get "/nodes/$PLUGIN_NODE/qemu/$NVMID/config")
  if vm_exists "$PLUGIN_NODE" "$NVMID"; then ok "VM $NVMID created"; else bad "VM not created"; fi
  jq -r '.data.net0' <<<"$CFG" | grep -qi "$MAC" && ok "pinned MAC applied" || bad "MAC not applied"
  jq -r '.data.ide2' <<<"$CFG" | grep -q "$REAL_ISO" && ok "ISO attached as cdrom" || bad "ISO not attached"

  run PLUGIN_ACTION=vm-destroy PLUGIN_NODE="$PLUGIN_NODE" PLUGIN_VMID="$NVMID" >/dev/null 2>&1
  if wait_gone qemu "$PLUGIN_NODE" "$NVMID"; then
    ok "VM destroyed cleanly, no orphan"
    CREATED_VM=("${CREATED_VM[@]/$PLUGIN_NODE:$NVMID}")
  else
    bad "VM $NVMID still present after destroy (ORPHAN)"
  fi
fi

# =============================================================================
# TEST 7 — snapshot create/delete (exercises _guest_type_path detection)
# =============================================================================
head "TEST 7: snapshot lifecycle (LXC)"
run PLUGIN_ACTION=lxc-create PLUGIN_NODE="$PLUGIN_NODE" \
    PLUGIN_HOSTNAME="citest-snap" PLUGIN_STORAGE="$TEST_STORAGE" \
    PLUGIN_OSTEMPLATE="$TEST_TEMPLATE" PLUGIN_CORES=1 PLUGIN_MEMORY=512 \
    PLUGIN_ROOTFS_SIZE=4 PLUGIN_START_ON_CREATE=false >/dev/null
SNVMID=$(run_var PROXMOX_VMID)
if [[ -n "$SNVMID" ]]; then
  CREATED_LXC+=("$PLUGIN_NODE:$SNVMID")
  SOUT=$(run PLUGIN_ACTION=snapshot-create PLUGIN_NODE="$PLUGIN_NODE" \
             PLUGIN_VMID="$SNVMID" PLUGIN_SNAPSHOT_NAME="citest1")
  if api_get "/nodes/$PLUGIN_NODE/lxc/$SNVMID/snapshot" | jq -e '.data[]? | select(.name=="citest1")' >/dev/null; then
    ok "snapshot created (guest type auto-detected)"
  else
    bad "snapshot not found after create"
  fi
  run PLUGIN_ACTION=snapshot-delete PLUGIN_NODE="$PLUGIN_NODE" PLUGIN_VMID="$SNVMID" PLUGIN_SNAPSHOT_NAME="citest1" >/dev/null 2>&1
  ok "snapshot-delete ran"
  # A bogus VMID must report a clean 'not found', NOT a false guest type
  GT=$(run PLUGIN_ACTION=snapshot-list PLUGIN_NODE="$PLUGIN_NODE" PLUGIN_VMID=99986 2>&1)
  grep -qi "not found" <<<"$GT" && ok "missing VMID reported as not-found (not misdiagnosed)" \
                                 || bad "missing VMID not cleanly reported"
  run PLUGIN_ACTION=lxc-destroy PLUGIN_NODE="$PLUGIN_NODE" PLUGIN_VMID="$SNVMID" >/dev/null 2>&1
  wait_gone lxc "$PLUGIN_NODE" "$SNVMID" && CREATED_LXC=("${CREATED_LXC[@]/$PLUGIN_NODE:$SNVMID}")
else
  bad "could not create container for snapshot test"
fi

# =============================================================================
# SUMMARY
# =============================================================================
head "SUMMARY"
echo "  passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]] && { echo "  ${c_grn}ALL TESTS PASSED${c_nc}"; exit 0; } \
                  || { echo "  ${c_red}$FAIL TEST(S) FAILED${c_nc}"; exit 1; }
