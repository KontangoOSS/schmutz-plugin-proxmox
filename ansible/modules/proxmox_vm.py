#!/usr/bin/python
# -*- coding: utf-8 -*-
"""
Ansible module: proxmox_vm — Manage QEMU/KVM VMs on Proxmox VE.
"""

DOCUMENTATION = r"""
module: proxmox_vm
short_description: Manage QEMU/KVM VMs on Proxmox VE
description:
  - Create, destroy, start, stop, and restart QEMU VMs.
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
    type: int
  state:
    description: Desired state
    choices: [present, absent, started, stopped, restarted]
    default: present
    type: str
  name:
    description: VM name
    type: str
  cores:
    description: CPU cores
    type: int
    default: 2
  memory:
    description: Memory in MB
    type: int
    default: 2048
  storage:
    description: Storage pool
    type: str
    default: local-zfs
  disk_size:
    description: Disk size in GB
    type: int
    default: 32
  iso:
    description: ISO image for install
    type: str
  bridge:
    description: Network bridge
    type: str
    default: vmbr0
  bios:
    description: BIOS type
    type: str
    default: seabios
  machine:
    description: Machine type
    type: str
    default: q35
  scsihw:
    description: SCSI controller
    type: str
    default: virtio-scsi-single
  os_type:
    description: OS type
    type: str
    default: l26
  timeout:
    description: Task timeout
    type: int
    default: 120
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
            state=dict(default="present", choices=["present", "absent", "started", "stopped", "restarted"]),
            name=dict(type="str"),
            cores=dict(type="int", default=2),
            memory=dict(type="int", default=2048),
            storage=dict(type="str", default="local-zfs"),
            disk_size=dict(type="int", default=32),
            iso=dict(type="str"),
            bridge=dict(type="str", default="vmbr0"),
            bios=dict(type="str", default="seabios"),
            machine=dict(type="str", default="q35"),
            scsihw=dict(type="str", default="virtio-scsi-single"),
            os_type=dict(type="str", default="l26"),
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

    exists = False
    current_status = None
    if vmid:
        try:
            info = api.get(f"/nodes/{node}/qemu/{vmid}/status/current")
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
            api.post_task(node, f"/nodes/{node}/qemu/{vmid}/status/stop", timeout=p["timeout"])
        upid = api.delete(f"/nodes/{node}/qemu/{vmid}")
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
            name=p["name"] or f"vm-{vmid}",
            cores=p["cores"],
            memory=p["memory"],
            bios=p["bios"],
            machine=p["machine"],
            scsihw=p["scsihw"],
            ostype=p["os_type"],
            scsi0=f"{p['storage']}:{p['disk_size']}",
            net0=f"model=virtio,bridge={p['bridge']}",
        )
        if p["iso"]:
            params["ide2"] = f"{p['iso']},media=cdrom"
        api.post_task(node, f"/nodes/{node}/qemu", timeout=p["timeout"], **params)
        result["changed"] = True
        module.exit_json(**result)

    if state == "started":
        if not exists:
            module.fail_json(msg=f"VM {vmid} does not exist")
        if current_status == "running":
            module.exit_json(**result)
        if module.check_mode:
            result["changed"] = True
            module.exit_json(**result)
        api.post_task(node, f"/nodes/{node}/qemu/{vmid}/status/start", timeout=p["timeout"])
        result["changed"] = True
        module.exit_json(**result)

    if state == "stopped":
        if not exists:
            module.fail_json(msg=f"VM {vmid} does not exist")
        if current_status == "stopped":
            module.exit_json(**result)
        if module.check_mode:
            result["changed"] = True
            module.exit_json(**result)
        api.post_task(node, f"/nodes/{node}/qemu/{vmid}/status/stop", timeout=p["timeout"])
        result["changed"] = True
        module.exit_json(**result)

    if state == "restarted":
        if not exists:
            module.fail_json(msg=f"VM {vmid} does not exist")
        if module.check_mode:
            result["changed"] = True
            module.exit_json(**result)
        api.post_task(node, f"/nodes/{node}/qemu/{vmid}/status/reboot", timeout=p["timeout"])
        result["changed"] = True
        module.exit_json(**result)


def main():
    run_module()


if __name__ == "__main__":
    main()
