---
title: Proxmox Plugin
version: 4.0.0
author: Kontango
image: ghcr.io/kontangooss/proxmox
tags: [proxmox, virtualization, infrastructure, lxc, qemu, ansible]
---

# Proxmox Plugin Documentation

Full-featured Proxmox VE management plugin for Woodpecker CI. Provides 94 actions for managing containers, VMs, storage, networking, and more through the Proxmox REST API. Includes Ansible roles, modules, and workflow playbooks for end-to-end provisioning and configuration.

## Authentication

The plugin uses PVE API tokens for authentication. Create a token in the Proxmox web UI under Datacenter > Permissions > API Tokens.

```
# Token format
user@realm!tokenid=uuid-secret-value

# Example
root@pam!woodpecker-ci=d6373e04-b038-4f08-b607-cf272529130d
```

Store the token as a Woodpecker secret named `pve_token`.

## Settings Reference

### Required

| Setting | Type | Description |
|---------|------|-------------|
| `action` | string | Action to perform (see action list below) |
| `api_url` | string | Proxmox API base URL, e.g. `https://pve.example.com:8006` |
| `api_token` | secret | PVE API token |
| `node` | string | Target Proxmox node name |

### Optional (Global)

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `auth_mode` | string | `pve` | Auth mode: `pve`, `bearer`, `api_key`, `basic`, `none` |
| `skip_verify` | bool | `true` | Skip TLS certificate verification |
| `debug` | bool | `false` | Enable verbose debug logging |
| `timeout` | int | `120` | Async task polling timeout in seconds |
| `retry_max` | int | `3` | Maximum HTTP retry attempts |
| `retry_delay` | int | `2` | Seconds between retries |
| `http_timeout` | int | `30` | HTTP connection timeout in seconds |

## Action Reference

### LXC Containers

#### lxc-list
List all containers on a node.

| Setting | Required | Description |
|---------|----------|-------------|
| `filter` | no | Regex filter on container name |

**Output:** `CONTAINER_COUNT`

#### lxc-create
Create a new LXC container.

| Setting | Required | Default | Description |
|---------|----------|---------|-------------|
| `vmid` | yes | — | Container ID |
| `hostname` | yes | — | Container hostname |
| `ostemplate` | no | `local:vztmpl/debian-12-standard...` | OS template |
| `storage` | no | `local-zfs` | Storage pool |
| `rootfs_size` | no | `8` | Root filesystem size in GB |
| `memory` | no | `2048` | Memory in MB |
| `swap` | no | `512` | Swap in MB |
| `cores` | no | `2` | CPU cores |
| `network` | no | `name=eth0,bridge=vmbr0,ip=dhcp` | Network config |
| `unprivileged` | no | `1` | Unprivileged container |
| `password` | no | — | Root password |
| `start_on_create` | no | `true` | Start after creation |
| `features` | no | `nesting=1` | Container features |

**Output:** `PROXMOX_VMID`, `PROXMOX_NODE`, `PROXMOX_STATUS`, `PROXMOX_IP`

#### lxc-get / lxc-status / lxc-interfaces
Query container config, status, or network interfaces.

| Setting | Required | Description |
|---------|----------|-------------|
| `vmid` | yes | Container ID |

#### lxc-start / lxc-stop / lxc-restart / lxc-destroy
Lifecycle actions. All require `vmid`.

#### lxc-resize
Resize container resources.

| Setting | Required | Description |
|---------|----------|-------------|
| `vmid` | yes | Container ID |
| `cores` | no | New CPU core count |
| `memory` | no | New memory in MB |
| `disk` | no | New disk size (e.g. `+2G`) |

#### lxc-exec
Execute a command inside a container via SSH + pct exec.

| Setting | Required | Description |
|---------|----------|-------------|
| `vmid` | yes | Container ID |
| `command` | yes | Command to execute |
| `ssh_password` | * | SSH password for Proxmox host |
| `ssh_key` | * | SSH private key |
| `ssh_host` | no | Override SSH host (derived from api_url) |

*One of `ssh_password` or `ssh_key` is required.

### QEMU Virtual Machines

Same pattern as LXC: `vm-list`, `vm-get`, `vm-create`, `vm-destroy`, `vm-start`, `vm-stop`, `vm-restart`.

Additional settings for `vm-create`: `name`, `cores`, `memory`, `storage`, `disk_size`, `iso`, `bridge`, `bios`, `machine`, `scsihw`, `os_type`.

### Snapshots & Backups

| Action | Required Settings | Description |
|--------|-------------------|-------------|
| `snapshot-create` | `vmid` | Create snapshot (auto-detects LXC/QEMU) |
| `snapshot-list` | `vmid` | List snapshots |
| `snapshot-rollback` | `vmid`, `snapshot_name` | Rollback to snapshot |
| `snapshot-delete` | `vmid`, `snapshot_name` | Delete snapshot |
| `backup-create` | `vmid` | Create vzdump backup |
| `backup-list` | `vmid` | List backups |

### Clone & Migrate

| Action | Required Settings | Description |
|--------|-------------------|-------------|
| `clone` | `vmid` | Clone VM/CT (auto-assigns new VMID) |
| `migrate` | `vmid`, `target_node` | Migrate between nodes |

### Storage Management

| Action | Required Settings | Description |
|--------|-------------------|-------------|
| `storage-list` | — | List storage pools |
| `storage-create` | `storage_id`, `storage_type` | Create storage |
| `storage-delete` | `storage_id` | Delete storage |
| `volume-list` | `storage_id` | List volumes |
| `iso-list` | — | List ISOs |
| `iso-upload` | `iso_url` | Download ISO from URL |
| `template-list` | — | List container templates |
| `template-download` | `template_url` | Download template from URL |
| `template-create` | `vmid` | Convert VM to template |
| `disk-import` | `vmid`, `disk_url` | Import disk image |

### Networking

| Action | Required Settings | Description |
|--------|-------------------|-------------|
| `network-list` | — | List network interfaces |
| `network-reload` | — | Reload network config |
| `bridge-create` | `iface` | Create Linux bridge |
| `bridge-delete` | `iface` | Delete interface |
| `vlan-create` | `iface`, `vlan_id` | Create VLAN interface |
| `sdn-zone-list` | — | List SDN zones |
| `sdn-zone-create` | `sdn_zone`, `sdn_type` | Create SDN zone |
| `sdn-vnet-create` | `sdn_vnet`, `sdn_zone` | Create VNet |
| `sdn-subnet-create` | `sdn_vnet`, `sdn_subnet` | Create subnet |

### Access Control

| Action | Required Settings | Description |
|--------|-------------------|-------------|
| `user-list` | — | List users |
| `user-create` | `userid`, `password` | Create user |
| `token-list` | `userid` | List API tokens |
| `token-create` | `userid`, `token_id` | Create API token |
| `acl-list` | — | List ACL entries |
| `acl-set` | `acl_path`, `role` | Set ACL |
| `role-list` | — | List roles |

### High Availability

| Action | Required Settings | Description |
|--------|-------------------|-------------|
| `ha-group-list` | — | List HA groups |
| `ha-group-create` | `ha_group`, `ha_nodes` | Create HA group |
| `ha-resource-add` | `vmid` | Add resource to HA |
| `ha-status` | — | Show HA status |

### Cloud-Init

| Action | Required Settings | Description |
|--------|-------------------|-------------|
| `cloud-init-set` | `vmid` | Configure cloud-init |
| `cloud-init-dump` | `vmid` | Dump cloud-init config |

Settings: `ci_user`, `ci_password`, `ssh_keys`, `ip_config`, `nameserver`, `searchdomain`, `ci_storage`.

### Certificates

| Action | Required Settings | Description |
|--------|-------------------|-------------|
| `cert-list` | — | List certificates |
| `cert-upload` | `cert`, `key` | Upload custom cert |
| `acme-setup` | — | Order ACME certificate |

### Bulk Operations

All require `vmids` (comma-separated list):
`bulk-start`, `bulk-stop`, `bulk-snapshot`, `bulk-backup`

### Other

| Action | Required Settings | Description |
|--------|-------------------|-------------|
| `task-list` | — | List recent tasks |
| `task-log` | `task_upid` | View task log |
| `vnc-url` | `vmid` | Get VNC proxy URL |
| `spice-config` | `vmid` | Get SPICE config |
| `metrics-server-create` | `metrics_id`, `metrics_type`, `metrics_host`, `metrics_port` | Create metrics server |
| `metrics-server-list` | — | List metrics servers |
| `replication-list` | — | List replication jobs |
| `replication-create` | `vmid`, `target_node` | Create replication |
| `replication-status` | — | Show replication status |
| `ceph-status` | — | Ceph cluster status |
| `ceph-pool-list` | — | List Ceph pools |
| `ceph-pool-create` | `ceph_pool` | Create Ceph pool |
| `ceph-osd-create` | `ceph_dev` | Create OSD |
| `vm-disk-add` | `vmid` | Add disk to VM |
| `vm-disk-resize` | `vmid`, `disk`, `size` | Resize VM disk |
| `vm-disk-move` | `vmid`, `disk`, `target_storage` | Move VM disk |
| `pci-list` | — | List PCI devices |
| `pci-passthrough` | `vmid`, `pci_id` | Passthrough PCI device |
| `pool-list` | — | List pools |
| `pool-create` | `pool_id` | Create pool |
| `pool-delete` | `pool_id` | Delete pool |
| `pool-add-member` | `pool_id` | Add members to pool |

## Pipeline Examples

### Create and configure a container

```yaml
steps:
  - name: create
    image: ghcr.io/kontangooss/proxmox
    settings:
      action: lxc-create
      api_url: https://pve:8006
      api_token: { from_secret: pve_token }
      node: pve
      vmid: 200
      hostname: app-server
      memory: 4096
      cores: 4

  - name: verify
    image: ghcr.io/kontangooss/proxmox
    settings:
      action: lxc-status
      api_url: https://pve:8006
      api_token: { from_secret: pve_token }
      node: pve
      vmid: 200
```

### Snapshot before deploy, rollback on failure

```yaml
steps:
  - name: snapshot
    image: ghcr.io/kontangooss/proxmox
    settings:
      action: snapshot-create
      api_url: https://pve:8006
      api_token: { from_secret: pve_token }
      node: pve
      vmid: 200
      snapshot_name: pre-deploy

  - name: deploy
    image: my-deploy-image
    commands:
      - ./deploy.sh

  - name: rollback
    image: ghcr.io/kontangooss/proxmox
    settings:
      action: snapshot-rollback
      api_url: https://pve:8006
      api_token: { from_secret: pve_token }
      node: pve
      vmid: 200
      snapshot_name: pre-deploy
    when:
      - status: failure
```

### Bulk operations

```yaml
steps:
  - name: stop-all
    image: ghcr.io/kontangooss/proxmox
    settings:
      action: bulk-stop
      api_url: https://pve:8006
      api_token: { from_secret: pve_token }
      node: pve
      vmids: "200,201,202,203"
```

### Provision and configure with Ansible

```yaml
steps:
  - name: provision
    image: ghcr.io/kontangooss/proxmox
    settings:
      action: workflow-provision
      api_url: https://pve:8006
      api_token: { from_secret: pve_token }
      node: pve
      vmid: 200
      hostname: app-server
      guest_type: lxc
      memory: 4096
      cores: 4
      configure_roles: '["base","docker","harden","monitoring"]'
```

### Safe deploy with auto-rollback

```yaml
steps:
  - name: safe-deploy
    image: ghcr.io/kontangooss/proxmox
    settings:
      action: workflow-safe-deploy
      api_url: https://pve:8006
      api_token: { from_secret: pve_token }
      node: pve
      vmid: 200
      app_name: myapp
      app_deploy_method: docker-compose
```

### Clone and test

```yaml
steps:
  - name: clone-staging
    image: ghcr.io/kontangooss/proxmox
    settings:
      action: workflow-clone
      api_url: https://pve:8006
      api_token: { from_secret: pve_token }
      node: pve
      vmid: 200
      clone_name: staging-app
      configure_roles: '["base"]'

  - name: test
    image: my-test-runner
    commands:
      - ./run-tests.sh --host staging-app

  - name: teardown
    image: ghcr.io/kontangooss/proxmox
    settings:
      action: workflow-teardown
      api_url: https://pve:8006
      api_token: { from_secret: pve_token }
      node: pve
      vmids: "${PROXMOX_VMID}"
    when:
      - status: [success, failure]
```

## Ansible Integration

The plugin ships with a full Ansible toolkit for configuration management after provisioning.

### Workflow Actions

| Action | Description |
|--------|-------------|
| `workflow-provision` | Create VM/CT and apply Ansible roles |
| `workflow-deploy` | Deploy application using the app_deploy role |
| `workflow-safe-deploy` | Snapshot, deploy, auto-rollback on failure |
| `workflow-clone` | Clone a VM/CT and optionally configure |
| `workflow-teardown` | Destroy one or more VMs/CTs |
| `ansible-run` | Run any custom Ansible playbook |

### Ansible Roles

| Role | Description |
|------|-------------|
| `base` | System packages, timezone, NTP, sysctl tuning, DNS |
| `docker` | Docker CE install, daemon config, compose plugin, registry auth |
| `harden` | SSH hardening, UFW firewall, fail2ban, kernel sysctl, auto-updates |
| `monitoring` | Prometheus node_exporter, Grafana Promtail for log shipping |
| `user_setup` | Create users, SSH keys, sudo config, password policy |
| `app_deploy` | Deploy apps via docker-compose, docker run, systemd, or script |

### Ansible Modules

Custom modules that call the Proxmox API directly — use them in your own playbooks:

| Module | Description |
|--------|-------------|
| `proxmox_lxc` | Create, destroy, start, stop, restart LXC containers |
| `proxmox_vm` | Create, destroy, start, stop, restart QEMU VMs |
| `proxmox_snapshot` | Create, delete, rollback snapshots |
| `proxmox_clone` | Clone VMs and containers |
| `proxmox_cloudinit` | Configure cloud-init on VMs |
| `proxmox_firewall` | Manage firewall rules at cluster/node/guest level |

All modules support `check_mode` and use `PVEAPIToken` authentication.

Example:

```yaml
- name: Create and configure a web server
  hosts: localhost
  tasks:
    - proxmox_lxc:
        api_url: https://pve:8006
        api_token: "root@pam!ci=secret"
        node: pve
        vmid: 200
        hostname: webserver
        memory: 4096
        state: present

    - proxmox_firewall:
        api_url: https://pve:8006
        api_token: "root@pam!ci=secret"
        node: pve
        vmid: 200
        action: ACCEPT
        type: in
        proto: tcp
        dport: "80,443"
```

### Dynamic Inventory

The `proxmox_inventory` plugin queries the Proxmox API and builds Ansible inventory automatically.

Create `proxmox.yml`:
```yaml
plugin: proxmox_inventory
api_url: https://pve:8006
api_token: root@pam!ansible=secret
verify_ssl: false
group_by_node: true
group_by_type: true
group_by_tags: true
filters:
  status: running
```

Then use it:
```bash
ansible-inventory -i proxmox.yml --list
ansible -i proxmox.yml lxc -m ping
```

Hosts are grouped by `lxc`/`qemu`, `node_<name>`, `tag_<tag>`, and `pool_<pool>`. Each host gets `proxmox_vmid`, `proxmox_node`, `proxmox_type`, and `ansible_host` (auto-detected IP) as host variables.
