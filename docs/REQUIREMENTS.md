# Requirements

What you need to run the `proxmox` Woodpecker plugin.

## 1. Woodpecker CI

- Woodpecker **2.x or newer** (uses the standard `settings:` / `from_secret:`
  plugin interface and `when: status: [...]` conditions).
- The agent must be able to pull the plugin image
  (`ghcr.io/kontangooss/proxmox:latest`) and reach your Proxmox API over the
  network.

## 2. Proxmox VE

- Proxmox VE **8.x or 9.x** (developed and tested against 9.1). The plugin
  targets the stable `/api2/json` REST API and assumes nothing version-specific,
  so older 7.x is likely to work but is untested.
- Network reachability from the Woodpecker agent to the Proxmox API port
  (default **8006/tcp**).

## 3. A Proxmox API token

Create a token for CI and give it only the privileges it needs. **Do not use
the root token.**

```bash
# On the Proxmox host, as root:
pveum user add ci@pve
pveum user token add ci@pve woodpecker --privsep 1
# → prints the token secret ONCE. Save it as the Woodpecker secret.
```

Grant a role scoped to what your pipelines actually do. A good starting role
for full LXC/VM provisioning:

```bash
pveum role add CIProvision --privs \
  "VM.Allocate VM.Clone VM.Config.CPU VM.Config.Disk VM.Config.Memory \
   VM.Config.Network VM.Config.Options VM.Config.CDROM VM.Config.Cloudinit \
   VM.PowerMgmt VM.Snapshot VM.Snapshot.Rollback VM.Audit \
   Datastore.AllocateSpace Datastore.Audit Datastore.AllocateTemplate \
   Sys.Audit Pool.Audit"
pveum acl modify / --roles CIProvision --tokens 'ci@pve!woodpecker'
```

Then add the token to Woodpecker as a secret (Repo → Settings → Secrets), in
the form the plugin expects:

```
user@realm!tokenid=secret
# e.g.  ci@pve!woodpecker=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

> **Privilege reference** — the minimum privileges per action group:
>
> | Action group                    | Privileges |
> |---------------------------------|------------|
> | `lxc-*` / `vm-*` create/config  | `VM.Allocate`, `VM.Config.*`, `Datastore.AllocateSpace` |
> | start/stop/destroy              | `VM.PowerMgmt`, `VM.Allocate` |
> | `snapshot-*`                    | `VM.Snapshot`, `VM.Snapshot.Rollback` |
> | `clone`                         | `VM.Clone` |
> | `iso-list` / `template-*`       | `Datastore.Audit`, `Datastore.AllocateTemplate` |
> | any list/get                    | `VM.Audit`, `Sys.Audit`, `Datastore.Audit` |

## 4. Optional: SSH access (only for in-guest actions)

Actions that run commands *inside* a guest — `lxc-exec` and
`lxc-create` with `update_on_create: true` — use `pct exec` on the Proxmox
host over SSH. For those you also provide:

- `ssh_host` — the Proxmox host to SSH into (defaults to the host in `api_url`)
- `ssh_key` — a private key (as a secret) **or** `ssh_password`
- `ssh_user` — defaults to `root`

Pure API actions (create, destroy, resize, snapshot, list, …) need **no** SSH.

## 5. TLS

Proxmox ships a self-signed certificate by default. The plugin sets
`skip_verify: true` by default for that reason. If you have a proper
certificate on your Proxmox API, set `skip_verify: false` to enforce
verification.
