#!/usr/bin/python
# -*- coding: utf-8 -*-
"""
Ansible module: proxmox_snapshot — Manage snapshots on Proxmox VE.
"""

DOCUMENTATION = r"""
module: proxmox_snapshot
short_description: Manage VM/CT snapshots on Proxmox VE
description:
  - Create, delete, and rollback snapshots for LXC containers and QEMU VMs.
options:
  api_url:
    description: Proxmox API URL
    required: true
    type: str
  api_token:
    description: PVE API token
    required: true
    type: str
  node:
    description: Proxmox node name
    required: true
    type: str
  vmid:
    description: VM or container ID
    required: true
    type: int
  state:
    description: Desired state
    choices: [present, absent, rollback]
    default: present
    type: str
  snapshot_name:
    description: Snapshot name (auto-generated if omitted for create)
    type: str
  description:
    description: Snapshot description
    type: str
  timeout:
    description: Task timeout
    type: int
    default: 120
  verify_ssl:
    description: Verify SSL
    type: bool
    default: false
"""

import time
from ansible.module_utils.proxmox_api import ProxmoxAPI

from ansible.module_utils.basic import AnsibleModule


def run_module():
    module = AnsibleModule(
        argument_spec=dict(
            api_url=dict(required=True, type="str"),
            api_token=dict(required=True, type="str", no_log=True),
            node=dict(required=True, type="str"),
            vmid=dict(required=True, type="int"),
            state=dict(default="present", choices=["present", "absent", "rollback"]),
            snapshot_name=dict(type="str"),
            description=dict(type="str", default=""),
            timeout=dict(type="int", default=120),
            verify_ssl=dict(type="bool", default=False),
        ),
        supports_check_mode=True,
    )

    p = module.params
    api = ProxmoxAPI(p["api_url"], p["api_token"], verify_ssl=p["verify_ssl"])
    node = p["node"]
    vmid = p["vmid"]
    state = p["state"]

    guest_type = api.guest_type(node, vmid)
    if not guest_type:
        module.fail_json(msg=f"VMID {vmid} not found on node {node}")

    base = f"/nodes/{node}/{guest_type}/{vmid}/snapshot"
    snap_name = p["snapshot_name"] or f"snap-{int(time.time())}"
    result = dict(changed=False, snapshot_name=snap_name)

    # List existing snapshots
    existing = [s["name"] for s in api.get(base) or [] if s.get("name") != "current"]
    snap_exists = snap_name in existing

    if state == "present":
        if snap_exists:
            module.exit_json(**result)
        if module.check_mode:
            result["changed"] = True
            module.exit_json(**result)
        params = dict(snapname=snap_name)
        if p["description"]:
            params["description"] = p["description"]
        api.post_task(node, base, timeout=p["timeout"], **params)
        result["changed"] = True
        module.exit_json(**result)

    if state == "absent":
        if not snap_exists:
            module.exit_json(**result)
        if module.check_mode:
            result["changed"] = True
            module.exit_json(**result)
        upid = api.delete(f"{base}/{snap_name}")
        if upid:
            api.wait_task(node, upid, timeout=p["timeout"])
        result["changed"] = True
        module.exit_json(**result)

    if state == "rollback":
        if not snap_exists:
            module.fail_json(msg=f"Snapshot '{snap_name}' not found")
        if module.check_mode:
            result["changed"] = True
            module.exit_json(**result)
        api.post_task(node, f"{base}/{snap_name}/rollback", timeout=p["timeout"])
        result["changed"] = True
        module.exit_json(**result)


def main():
    run_module()


if __name__ == "__main__":
    main()
