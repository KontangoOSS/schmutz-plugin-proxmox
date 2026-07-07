#!/usr/bin/python
# -*- coding: utf-8 -*-
"""
Ansible module: proxmox_firewall — Manage Proxmox VE firewall rules.
"""

DOCUMENTATION = r"""
module: proxmox_firewall
short_description: Manage firewall rules on Proxmox VE
description:
  - Add and remove firewall rules at cluster, node, or guest level.
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
    description: VM/CT ID (omit for cluster/node-level rules)
    type: int
  state:
    description: Desired state
    choices: [present, absent]
    default: present
    type: str
  scope:
    description: Rule scope
    choices: [cluster, node, guest]
    default: guest
    type: str
  action:
    description: "Rule action: ACCEPT, DROP, REJECT"
    type: str
    default: ACCEPT
  type:
    description: "Rule direction: in, out, group"
    type: str
    default: in
  proto:
    description: Protocol (tcp, udp, icmp)
    type: str
  dport:
    description: Destination port or range
    type: str
  sport:
    description: Source port or range
    type: str
  source:
    description: Source address/CIDR
    type: str
  dest:
    description: Destination address/CIDR
    type: str
  comment:
    description: Rule comment
    type: str
  enable:
    description: Enable rule
    type: bool
    default: true
  pos:
    description: Rule position
    type: int
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
            vmid=dict(type="int"),
            state=dict(default="present", choices=["present", "absent"]),
            scope=dict(default="guest", choices=["cluster", "node", "guest"]),
            action=dict(type="str", default="ACCEPT"),
            type=dict(type="str", default="in"),
            proto=dict(type="str"),
            dport=dict(type="str"),
            sport=dict(type="str"),
            source=dict(type="str"),
            dest=dict(type="str"),
            comment=dict(type="str"),
            enable=dict(type="bool", default=True),
            pos=dict(type="int"),
            verify_ssl=dict(type="bool", default=False),
        ),
        supports_check_mode=True,
    )

    p = module.params
    api = ProxmoxAPI(p["api_url"], p["api_token"], verify_ssl=p["verify_ssl"])
    node = p["node"]
    vmid = p["vmid"]
    state = p["state"]
    scope = p["scope"]

    # Build firewall path
    if scope == "cluster":
        base = "/cluster/firewall/rules"
    elif scope == "node":
        base = f"/nodes/{node}/firewall/rules"
    else:
        if not vmid:
            module.fail_json(msg="vmid required for guest-level firewall rules")
        guest_type = api.guest_type(node, vmid)
        if not guest_type:
            module.fail_json(msg=f"VMID {vmid} not found")
        base = f"/nodes/{node}/{guest_type}/{vmid}/firewall/rules"

    if module.check_mode:
        module.exit_json(changed=True)

    if state == "present":
        params = dict(
            action=p["action"],
            type=p["type"],
            enable=1 if p["enable"] else 0,
        )
        for key in ("proto", "dport", "sport", "source", "dest", "comment"):
            if p[key]:
                params[key] = p[key]
        if p["pos"] is not None:
            params["pos"] = p["pos"]
        api.post(base, **params)
        module.exit_json(changed=True)

    if state == "absent":
        if p["pos"] is None:
            module.fail_json(msg="'pos' is required to delete a firewall rule")
        api.delete(f"{base}/{p['pos']}")
        module.exit_json(changed=True)


def main():
    run_module()


if __name__ == "__main__":
    main()
