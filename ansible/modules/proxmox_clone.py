#!/usr/bin/python
# -*- coding: utf-8 -*-
"""
Ansible module: proxmox_clone — Clone VMs/CTs on Proxmox VE.
"""

DOCUMENTATION = r"""
module: proxmox_clone
short_description: Clone VMs and containers on Proxmox VE
description:
  - Clone an existing VM or container, optionally to a different node or storage.
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
    description: Source Proxmox node
    required: true
    type: str
  vmid:
    description: Source VMID
    required: true
    type: int
  newid:
    description: Target VMID (auto-assigned if omitted)
    type: int
  name:
    description: Name for the clone
    type: str
  target_node:
    description: Target node (same node if omitted)
    type: str
  storage:
    description: Target storage
    type: str
  full:
    description: Full clone (vs linked)
    type: bool
    default: true
  timeout:
    description: Task timeout
    type: int
    default: 300
  verify_ssl:
    description: Verify SSL
    type: bool
    default: false
"""

from ansible.module_utils.proxmox_api import ProxmoxAPI

from ansible.module_utils.basic import AnsibleModule


def run_module():
    module = AnsibleModule(
        argument_spec=dict(
            api_url=dict(required=True, type="str"),
            api_token=dict(required=True, type="str", no_log=True),
            node=dict(required=True, type="str"),
            vmid=dict(required=True, type="int"),
            newid=dict(type="int"),
            name=dict(type="str"),
            target_node=dict(type="str"),
            storage=dict(type="str"),
            full=dict(type="bool", default=True),
            timeout=dict(type="int", default=300),
            verify_ssl=dict(type="bool", default=False),
        ),
        supports_check_mode=True,
    )

    p = module.params
    api = ProxmoxAPI(p["api_url"], p["api_token"], verify_ssl=p["verify_ssl"])
    node = p["node"]
    vmid = p["vmid"]

    guest_type = api.guest_type(node, vmid)
    if not guest_type:
        module.fail_json(msg=f"VMID {vmid} not found on node {node}")

    newid = p["newid"] or api.next_vmid()
    result = dict(changed=False, vmid=vmid, newid=newid)

    # Check if target already exists
    target_type = api.guest_type(p["target_node"] or node, newid)
    if target_type:
        module.exit_json(**result)

    if module.check_mode:
        result["changed"] = True
        module.exit_json(**result)

    params = dict(newid=newid, full=1 if p["full"] else 0)
    if p["name"]:
        # LXC clone uses 'hostname', QEMU clone uses 'name'
        name_key = "hostname" if guest_type == "lxc" else "name"
        params[name_key] = p["name"]
    if p["target_node"]:
        params["target"] = p["target_node"]
    if p["storage"]:
        params["storage"] = p["storage"]

    path = f"/nodes/{node}/{guest_type}/{vmid}/clone"
    api.post_task(node, path, timeout=p["timeout"], **params)
    result["changed"] = True
    module.exit_json(**result)


def main():
    run_module()


if __name__ == "__main__":
    main()
