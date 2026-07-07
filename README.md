# Proxmox Woodpecker CI Plugin

Manage Proxmox VE infrastructure from Woodpecker CI pipelines. 94 actions covering LXC containers, QEMU VMs, storage, networking, snapshots, backups, HA, Ceph, and more. Ships with Ansible roles, modules, and workflow playbooks for end-to-end provisioning and configuration management.

Built and maintained by the team at [Kontango](https://kontango.net).

- **Requirements & setup** (Proxmox token, privileges, network): [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)
- **Runnable pipeline examples**: [examples/](examples/) — single LXC, multi-instance, VM-from-ISO, ephemeral CI env
- **Full action & settings reference**: [docs.md](docs.md)

## Quick Start

```yaml
steps:
  - name: create-container
    image: ghcr.io/kontangooss/proxmox
    settings:
      action: lxc-create
      api_url: https://pve.example.com:8006
      api_token:
        from_secret: pve_token
      node: pve
      vmid: 200
      hostname: my-container
      memory: 2048
      cores: 2
      start_on_create: true
```

### Provision + configure in one step

```yaml
steps:
  - name: provision
    image: ghcr.io/kontangooss/proxmox
    settings:
      action: workflow-provision
      api_url: https://pve.example.com:8006
      api_token: { from_secret: pve_token }
      node: pve
      vmid: 200
      hostname: app-server
      guest_type: lxc
      configure_roles: '["base","docker","harden"]'
```

## Settings

| Setting | Required | Default | Description |
|---------|----------|---------|-------------|
| `action` | yes | — | Action to perform |
| `api_url` | yes | — | Proxmox API URL |
| `api_token` | yes | — | PVE API token (`user@realm!tokenid=secret`) |
| `node` | yes | — | Proxmox node name |
| `auth_mode` | no | `pve` | Auth mode: `pve`, `bearer`, `api_key`, `basic` |
| `skip_verify` | no | `true` | Skip TLS verification |
| `debug` | no | `false` | Enable debug logging |
| `timeout` | no | `120` | Task polling timeout (seconds) |
| `retry_max` | no | `3` | Max HTTP retries |

## Actions

### Containers (LXC)
`lxc-list` `lxc-get` `lxc-create` `lxc-destroy` `lxc-start` `lxc-stop` `lxc-restart` `lxc-status` `lxc-resize` `lxc-interfaces` `lxc-exec`

### Virtual Machines (QEMU)
`vm-list` `vm-get` `vm-create` `vm-destroy` `vm-start` `vm-stop` `vm-restart`

### Snapshots & Backups
`snapshot-create` `snapshot-list` `snapshot-rollback` `snapshot-delete` `backup-create` `backup-list`

### Clone & Migrate
`clone` `migrate`

### Nodes & Cluster
`node-list` `node-status` `next-vmid` `cluster-status` `cluster-resources`

### Storage
`storage-list` `storage-create` `storage-delete` `volume-list` `template-list` `template-download` `template-create` `iso-list` `iso-upload` `disk-import`

### Networking & SDN
`network-list` `network-reload` `bridge-create` `bridge-delete` `vlan-create` `sdn-zone-list` `sdn-zone-create` `sdn-vnet-create` `sdn-subnet-create`

### Firewall
`firewall-rules` `firewall-add` `firewall-delete` `firewall-options`

### Access Control
`user-list` `user-create` `token-list` `token-create` `acl-list` `acl-set` `role-list`

### Resource Pools
`pool-list` `pool-create` `pool-delete` `pool-add-member`

### High Availability
`ha-group-list` `ha-group-create` `ha-resource-add` `ha-status`

### VM Disks & PCI
`vm-disk-add` `vm-disk-resize` `vm-disk-move` `pci-list` `pci-passthrough`

### Cloud-Init
`cloud-init-set` `cloud-init-dump`

### Certificates
`cert-list` `cert-upload` `acme-setup`

### Replication
`replication-list` `replication-create` `replication-status`

### Ceph
`ceph-status` `ceph-pool-list` `ceph-pool-create` `ceph-osd-create`

### Bulk Operations
`bulk-start` `bulk-stop` `bulk-snapshot` `bulk-backup`

### Tasks & Console
`task-list` `task-log` `vnc-url` `spice-config`

### Metrics
`metrics-server-create` `metrics-server-list`

### Workflows (Ansible)
`workflow-provision` `workflow-deploy` `workflow-safe-deploy` `workflow-clone` `workflow-teardown` `ansible-run`

## Ansible

The plugin includes a full Ansible toolkit for post-provisioning configuration.

### Roles

| Role | Description |
|------|-------------|
| `base` | System packages, timezone, NTP, sysctl, DNS |
| `docker` | Docker CE, daemon config, compose, registry |
| `harden` | SSH hardening, UFW, fail2ban, kernel tuning |
| `monitoring` | Prometheus node_exporter, Promtail |
| `user_setup` | Users, SSH keys, sudo, password policy |
| `app_deploy` | Deploy via docker-compose, docker run, systemd, or script |

### Modules

| Module | Description |
|--------|-------------|
| `proxmox_lxc` | LXC lifecycle (present/absent/started/stopped/restarted) |
| `proxmox_vm` | QEMU lifecycle |
| `proxmox_snapshot` | Snapshot create/delete/rollback |
| `proxmox_clone` | Clone VMs and containers |
| `proxmox_cloudinit` | Cloud-init configuration |
| `proxmox_firewall` | Firewall rules at any scope |

### Dynamic Inventory

Auto-generates Ansible inventory from running Proxmox guests. Groups by node, type, tags, and pool.

```yaml
# proxmox.yml
plugin: proxmox_inventory
api_url: https://pve:8006
api_token: root@pam!ansible=secret
filters:
  status: running
```

## Local Testing

```bash
docker build -t proxmox-plugin .
./test.sh action=node-list api_url=https://pve:8006 api_token=root@pam!ci=secret node=pve
```

## Output Variables

| Variable | Actions | Description |
|----------|---------|-------------|
| `PROXMOX_VMID` | create, clone | Created/cloned VMID |
| `PROXMOX_IP` | create, start, interfaces | Container/VM IP |
| `PROXMOX_STATUS` | status | Current status |
| `SNAPSHOT_NAME` | snapshot-create | Created snapshot name |
| `NEXT_VMID` | next-vmid | Next available VMID |

## Architecture

```
plugin.sh               — Entry point, settings schema, dispatch
lib/plugin-core.sh      — Logging, validation, HTTP, auth, output
lib/pve-api.sh          — Proxmox API wrapper, task polling
lib/pve-lxc.sh          — LXC container actions
lib/pve-vm.sh           — QEMU VM actions
lib/pve-node.sh         — Node/cluster/storage/network queries
lib/pve-snapshot.sh     — Snapshot and backup actions
lib/pve-clone.sh        — Clone and migrate
lib/pve-exec.sh         — SSH exec into containers
lib/pve-firewall.sh     — Firewall management
lib/pve-access.sh       — Users, tokens, ACLs
lib/pve-storage-mgmt.sh — Storage, ISO, template management
lib/pve-network-mgmt.sh — Bridge, VLAN, SDN management
lib/pve-pool.sh         — Resource pools
lib/pve-ha.sh           — High availability
lib/pve-disk.sh         — VM disks, PCI passthrough
lib/pve-cloud-init.sh   — Cloud-init configuration
lib/pve-cert.sh         — TLS certificates
lib/pve-replication.sh  — Storage replication
lib/pve-ceph.sh         — Ceph management
lib/pve-bulk.sh         — Bulk operations
lib/pve-console.sh      — VNC/SPICE console access
lib/pve-task.sh         — Task management
lib/pve-metrics.sh      — Metrics server configuration
lib/pve-workflow.sh     — Ansible workflow dispatcher
ansible/
  roles/                — Configuration management roles
  modules/              — Custom Ansible modules for Proxmox API
  plugins/inventory/    — Dynamic inventory plugin
  playbooks/            — Workflow playbooks
```

---

## License

MIT. See [LICENSE](LICENSE).

---

<p align="center">
  Built by the team at <a href="https://kontango.net">Kontango</a>
</p>
