#!/usr/bin/python
# -*- coding: utf-8 -*-
"""
Ansible module: proxmox_lxc — Manage LXC containers on Proxmox VE.

Supports create, destroy, start, stop, restart, and resize.
"""

DOCUMENTATION = r"""
module: proxmox_lxc
short_description: Manage LXC containers on Proxmox VE
description:
  - Create, destroy, start, stop, restart, and resize LXC containers.
options:
  api_url:
    description: Proxmox API URL
    required: true
    type: str
  api_token:
    description: PVE API token (user@realm!tokenid=secret)
    required: true
    type: str
  node:
    description: Proxmox node name
    required: true
    type: str
  vmid:
    description: Container VMID (auto-assigned if omitted for create)
    type: int
  state:
    description: Desired state
    choices: [present, absent, started, stopped, restarted]
    default: present
    type: str
  hostname:
    description: Container hostname
    type: str
  ostemplate:
    description: OS template
    type: str
    default: "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
  storage:
    description: Storage pool
    type: str
    default: local-zfs
  rootfs_size:
    description: Root filesystem size in GB
    type: int
    default: 8
  memory:
    description: Memory in MB
    type: int
    default: 2048
  swap:
    description: Swap in MB
    type: int
    default: 512
  cores:
    description: CPU cores
    type: int
    default: 2
  network:
    description: Network configuration string
    type: str
    default: "name=eth0,bridge=vmbr0,ip=dhcp"
  unprivileged:
    description: Unprivileged container
    type: bool
    default: true
  features:
    description: Container features
    type: str
    default: "nesting=1"
  password:
    description: Root password
    type: str
  start_on_create:
    description: Start after creation
    type: bool
    default: true
  timeout:
    description: Task polling timeout in seconds
    type: int
    default: 120
  verify_ssl:
    description: Verify SSL certificates
    type: bool
    default: false
"""

EXAMPLES = r"""
- name: Create a container
  proxmox_lxc:
    api_url: https://pve:8006
    api_token: "root@pam!ci=secret"
    node: pve
    vmid: 200
    hostname: webserver
    memory: 4096
    cores: 4
    state: present

- name: Stop and destroy
  proxmox_lxc:
    api_url: https://pve:8006
    api_token: "root@pam!ci=secret"
    node: pve
    vmid: 200
    state: absent
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
            state=dict(default="present", choices=["present", "absent", "started", "stopped", "restarted"]),
            hostname=dict(type="str"),
            ostemplate=dict(type="str", default="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"),
            storage=dict(type="str", default="local-zfs"),
            rootfs_size=dict(type="int", default=8),
            memory=dict(type="int", default=2048),
            swap=dict(type="int", default=512),
            cores=dict(type="int", default=2),
            network=dict(type="str", default="name=eth0,bridge=vmbr0,ip=dhcp"),
            unprivileged=dict(type="bool", default=True),
            features=dict(type="str", default="nesting=1"),
            password=dict(type="str", no_log=True),
            start_on_create=dict(type="bool", default=True),
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

    # Check if container exists
    exists = False
    current_status = None
    if vmid:
        try:
            info = api.get(f"/nodes/{node}/lxc/{vmid}/status/current")
            exists = True
            current_status = info.get("status")
        except RuntimeError:
            pass

    result = dict(changed=False, vmid=vmid)

    if state == "absent":
        if not exists:
            module.exit_json(**result)
        if module.check_mode:
            result["changed"] = True
            module.exit_json(**result)
        if current_status == "running":
            api.post_task(node, f"/nodes/{node}/lxc/{vmid}/status/stop", timeout=p["timeout"])
        upid = api.delete(f"/nodes/{node}/lxc/{vmid}")
        if upid:
            api.wait_task(node, upid, timeout=p["timeout"])
        result["changed"] = True
        module.exit_json(**result)

    if state == "present":
        if exists:
            module.exit_json(**result)
        if module.check_mode:
            result["changed"] = True
            module.exit_json(**result)
        if not vmid:
            vmid = api.next_vmid()
            result["vmid"] = vmid
        params = dict(
            vmid=vmid,
            hostname=p["hostname"] or f"ct-{vmid}",
            ostemplate=p["ostemplate"],
            storage=p["storage"],
            rootfs=f"{p['storage']}:{p['rootfs_size']}",
            memory=p["memory"],
            swap=p["swap"],
            cores=p["cores"],
            net0=p["network"],
            unprivileged=1 if p["unprivileged"] else 0,
            start=1 if p["start_on_create"] else 0,
        )
        if p["features"]:
            params["features"] = p["features"]
        if p["password"]:
            params["password"] = p["password"]
        api.post_task(node, f"/nodes/{node}/lxc", timeout=p["timeout"], **params)
        result["changed"] = True
        module.exit_json(**result)

    if state == "started":
        if not exists:
            module.fail_json(msg=f"Container {vmid} does not exist")
        if current_status == "running":
            module.exit_json(**result)
        if module.check_mode:
            result["changed"] = True
            module.exit_json(**result)
        api.post_task(node, f"/nodes/{node}/lxc/{vmid}/status/start", timeout=p["timeout"])
        result["changed"] = True
        module.exit_json(**result)

    if state == "stopped":
        if not exists:
            module.fail_json(msg=f"Container {vmid} does not exist")
        if current_status == "stopped":
            module.exit_json(**result)
        if module.check_mode:
            result["changed"] = True
            module.exit_json(**result)
        api.post_task(node, f"/nodes/{node}/lxc/{vmid}/status/stop", timeout=p["timeout"])
        result["changed"] = True
        module.exit_json(**result)

    if state == "restarted":
        if not exists:
            module.fail_json(msg=f"Container {vmid} does not exist")
        if module.check_mode:
            result["changed"] = True
            module.exit_json(**result)
        api.post_task(node, f"/nodes/{node}/lxc/{vmid}/status/reboot", timeout=p["timeout"])
        result["changed"] = True
        module.exit_json(**result)


def main():
    run_module()


if __name__ == "__main__":
    main()
