#!/usr/bin/python
# -*- coding: utf-8 -*-
"""
Ansible module: proxmox_cloudinit — Configure cloud-init on Proxmox VMs.
"""

DOCUMENTATION = r"""
module: proxmox_cloudinit
short_description: Configure cloud-init for Proxmox VMs
description:
  - Set cloud-init parameters on a QEMU VM (user, password, SSH keys, network).
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
    description: VM ID
    required: true
    type: int
  ci_user:
    description: Cloud-init user
    type: str
  ci_password:
    description: Cloud-init password
    type: str
  ssh_keys:
    description: SSH public keys (newline-separated)
    type: str
  ip_config:
    description: "IP config (e.g. ip=dhcp or ip=10.0.0.2/24,gw=10.0.0.1)"
    type: str
  nameserver:
    description: DNS nameserver
    type: str
  searchdomain:
    description: DNS search domain
    type: str
  ci_storage:
    description: Storage for cloud-init drive
    type: str
  verify_ssl:
    description: Verify SSL
    type: bool
    default: false
"""

import urllib.parse
from ansible.module_utils.proxmox_api import ProxmoxAPI

from ansible.module_utils.basic import AnsibleModule


def run_module():
    module = AnsibleModule(
        argument_spec=dict(
            api_url=dict(required=True, type="str"),
            api_token=dict(required=True, type="str", no_log=True),
            node=dict(required=True, type="str"),
            vmid=dict(required=True, type="int"),
            ci_user=dict(type="str"),
            ci_password=dict(type="str", no_log=True),
            ssh_keys=dict(type="str"),
            ip_config=dict(type="str"),
            nameserver=dict(type="str"),
            searchdomain=dict(type="str"),
            ci_storage=dict(type="str"),
            verify_ssl=dict(type="bool", default=False),
        ),
        supports_check_mode=True,
    )

    p = module.params
    api = ProxmoxAPI(p["api_url"], p["api_token"], verify_ssl=p["verify_ssl"])
    node = p["node"]
    vmid = p["vmid"]

    if module.check_mode:
        module.exit_json(changed=True)

    params = {}
    if p["ci_user"]:
        params["ciuser"] = p["ci_user"]
    if p["ci_password"]:
        params["cipassword"] = p["ci_password"]
    if p["ssh_keys"]:
        params["sshkeys"] = urllib.parse.quote(p["ssh_keys"], safe="")
    if p["ip_config"]:
        params["ipconfig0"] = p["ip_config"]
    if p["nameserver"]:
        params["nameserver"] = p["nameserver"]
    if p["searchdomain"]:
        params["searchdomain"] = p["searchdomain"]
    if p["ci_storage"]:
        params["ide2"] = f"{p['ci_storage']}:cloudinit"

    if not params:
        module.exit_json(changed=False, msg="No cloud-init parameters specified")

    api.put(f"/nodes/{node}/qemu/{vmid}/config", **params)
    module.exit_json(changed=True, vmid=vmid)


def main():
    run_module()


if __name__ == "__main__":
    main()
