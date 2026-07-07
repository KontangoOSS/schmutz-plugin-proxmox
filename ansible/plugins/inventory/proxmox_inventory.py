#!/usr/bin/python
# -*- coding: utf-8 -*-
"""
Ansible dynamic inventory plugin for Proxmox VE.

Queries the Proxmox API and builds inventory from running VMs and containers.
Guests are grouped by type (lxc, qemu), node, and tags.

Configuration file: proxmox.yml or proxmox_inventory.yml

Example:
  plugin: proxmox_inventory
  api_url: https://pve.example.com:8006
  api_token: root@pam!ansible=secret-uuid
  verify_ssl: false
  group_by_node: true
  group_by_type: true
  group_by_tags: true
  filters:
    status: running
"""

DOCUMENTATION = r"""
name: proxmox_inventory
plugin_type: inventory
short_description: Proxmox VE dynamic inventory
description:
  - Builds inventory from Proxmox VE cluster resources.
  - Groups hosts by node, type (lxc/qemu), tags, and pool.
options:
  api_url:
    description: Proxmox API URL
    required: true
    env:
      - name: PROXMOX_API_URL
  api_token:
    description: PVE API token
    required: true
    env:
      - name: PROXMOX_API_TOKEN
  verify_ssl:
    description: Verify SSL certificates
    default: false
    type: bool
  group_by_node:
    description: Create groups by node name
    default: true
    type: bool
  group_by_type:
    description: Create groups by guest type (lxc, qemu)
    default: true
    type: bool
  group_by_tags:
    description: Create groups from guest tags
    default: true
    type: bool
  group_by_pool:
    description: Create groups by resource pool
    default: true
    type: bool
  filters:
    description: Filter guests by field values
    type: dict
    default: {}
  compose:
    description: Jinja2 expressions for host variables
    type: dict
    default: {}
  host_ip_field:
    description: Which interface to use for ansible_host
    default: auto
    type: str
"""

import json
import ssl
import urllib.request
import urllib.parse

from ansible.plugins.inventory import BaseInventoryPlugin, Constructable


class InventoryModule(BaseInventoryPlugin, Constructable):
    NAME = "proxmox_inventory"

    def verify_file(self, path):
        valid = False
        if super().verify_file(path):
            if path.endswith(("proxmox.yml", "proxmox.yaml",
                              "proxmox_inventory.yml", "proxmox_inventory.yaml")):
                valid = True
        return valid

    def parse(self, inventory, loader, path, cache=True):
        super().parse(inventory, loader, path, cache)
        self._read_config_data(path)

        api_url = self.get_option("api_url")
        api_token = self.get_option("api_token")
        verify_ssl = self.get_option("verify_ssl")
        filters = self.get_option("filters") or {}

        ctx = ssl.create_default_context()
        if not verify_ssl:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE

        base = api_url.rstrip("/") + "/api2/json"
        headers = {"Authorization": f"PVEAPIToken={api_token}"}

        def api_get(path):
            req = urllib.request.Request(base + path, headers=headers)
            resp = urllib.request.urlopen(req, timeout=30, context=ctx)
            return json.loads(resp.read().decode()).get("data", [])

        # Get cluster resources (VMs + CTs)
        resources = api_get("/cluster/resources?type=vm")

        for guest in resources:
            # Apply filters
            skip = False
            for key, val in filters.items():
                if str(guest.get(key, "")) != str(val):
                    skip = True
                    break
            if skip:
                continue

            name = guest.get("name")
            if not name:
                continue

            vmid = guest.get("vmid")
            node = guest.get("node")
            guest_type = guest.get("type", "")  # "lxc" or "qemu"
            status = guest.get("status", "")
            tags = guest.get("tags", "")
            pool = guest.get("pool", "")

            # Add host
            self.inventory.add_host(name)

            # Set standard vars
            self.inventory.set_variable(name, "proxmox_vmid", vmid)
            self.inventory.set_variable(name, "proxmox_node", node)
            self.inventory.set_variable(name, "proxmox_type", guest_type)
            self.inventory.set_variable(name, "proxmox_status", status)

            # Try to get IP
            if status == "running":
                ip = self._get_guest_ip(api_get, node, vmid, guest_type)
                if ip:
                    self.inventory.set_variable(name, "ansible_host", ip)
                    self.inventory.set_variable(name, "proxmox_ip", ip)

            # Set resource info
            for field in ("maxcpu", "maxmem", "maxdisk", "uptime"):
                if field in guest:
                    self.inventory.set_variable(name, f"proxmox_{field}", guest[field])

            # Group by type
            if self.get_option("group_by_type") and guest_type:
                self.inventory.add_group(guest_type)
                self.inventory.add_host(name, group=guest_type)

            # Group by node
            if self.get_option("group_by_node") and node:
                group = f"node_{node}"
                self.inventory.add_group(group)
                self.inventory.add_host(name, group=group)

            # Group by tags
            if self.get_option("group_by_tags") and tags:
                for tag in tags.split(";"):
                    tag = tag.strip()
                    if tag:
                        group = f"tag_{tag}"
                        self.inventory.add_group(group)
                        self.inventory.add_host(name, group=group)

            # Group by pool
            if self.get_option("group_by_pool") and pool:
                group = f"pool_{pool}"
                self.inventory.add_group(group)
                self.inventory.add_host(name, group=group)

    def _get_guest_ip(self, api_get, node, vmid, guest_type):
        """Try to get the primary IP of a guest."""
        try:
            if guest_type == "lxc":
                ifaces = api_get(f"/nodes/{node}/lxc/{vmid}/interfaces")
                for iface in ifaces or []:
                    if iface.get("name") != "lo":
                        ip = iface.get("inet-address") or iface.get("inet")
                        if ip:
                            return ip.split("/")[0]
            elif guest_type == "qemu":
                ifaces = api_get(f"/nodes/{node}/qemu/{vmid}/agent/network-get-interfaces")
                for iface in ifaces or []:
                    if iface.get("name") != "lo":
                        for addr in iface.get("ip-addresses", []):
                            if addr.get("ip-address-type") == "ipv4":
                                return addr["ip-address"]
        except Exception:
            pass
        return None
