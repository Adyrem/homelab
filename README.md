# Homelab

Proxmox VE homelab running on an Intel i7-8700 / 32 GB machine. All infrastructure is managed via Ansible. Secrets are encrypted with `ansible-vault`.

---

## Infrastructure Overview

| Component | Type | IP | Purpose |
|---|---|---|---|
| Proxmox host | bare metal | 192.168.1.10 | Hypervisor, WireGuard VPN server |
| gitea | VM 100 | 10.10.1.125 | Self-hosted Git + CI runner |
| monitoring | VM 101 | 10.10.1.137 | Prometheus, Grafana, Loki, Alertmanager |
| windows | VM 102 | — | Visual Studio (SPICE via Proxmox UI) |
| pihole | LXC 103 | 10.10.1.2 | DNS + ad blocking |
| traefik | LXC 104 | 10.10.1.3 | Reverse proxy + Let's Encrypt |
| claude-code | VM 105 | 10.10.2.10 | Persistent Claude Code session VM |

**Networks:**
- `vmbr1` 10.10.1.0/24 — infra (Gitea, monitoring, Pi-hole, Traefik)
- `vmbr2` 10.10.2.0/24 — dev (Claude Code VM)
- `vmbr3` 10.10.3.0/24 — desktop (Windows VM, isolated)

**Public endpoints:**
- `https://adyrem.duckdns.org/git` — Gitea
- Grafana: `http://10.10.1.137:3000` (VPN/LAN only)
- Proxmox UI: `https://10.10.1.10:8006` (VPN/LAN only; use `https://10.10.10.1:8006` over WireGuard)

---

## Prerequisites

- Ansible installed locally (`pip install ansible ansible-lint`)
- Vault password stored at `~/.config/homelab/vault_pass`
- WireGuard connected (for remote access) or on the LAN

```bash
cd ansible
export ANSIBLE_VAULT_PASSWORD_FILE=~/.config/homelab/vault_pass
```

---

## Day-to-day Operations

### SSH aliases (defined in `~/.ssh/config`)

```bash
ssh proxmox          # Proxmox host (port 2222, user adyrem)
ssh gitea-vm         # Gitea VM (via ProxyJump)
ssh monitoring-vm    # Monitoring VM (via ProxyJump)
ssh pihole-ct        # Pi-hole LXC (via ProxyJump)
ssh traefik-ct       # Traefik LXC (via ProxyJump)
ssh claude-code-vm   # Claude Code VM (via ProxyJump)
```

### Running playbooks

```bash
cd ansible
ansible-playbook playbooks/host.yml          # Proxmox host config
ansible-playbook playbooks/gitea.yml         # Gitea VM
ansible-playbook playbooks/monitoring.yml    # Monitoring stack
ansible-playbook playbooks/pihole.yml        # Pi-hole
ansible-playbook playbooks/traefik.yml       # Traefik
ansible-playbook playbooks/claude-code-vm.yml
ansible-playbook playbooks/site.yml          # All Arch VMs (common + node_exporter + promtail)
```

### Adding a WireGuard client

See [`ansible/playbooks/wireguard-README.md`](ansible/playbooks/wireguard-README.md) for step-by-step instructions.

---

## VPN Client Setup

WireGuard VPN is hosted on the Proxmox host (`adyrem.duckdns.org:51820`).

### Linux

```bash
# Install WireGuard
sudo apt install wireguard   # Debian/Ubuntu
sudo pacman -S wireguard-tools  # Arch

# Create config at /etc/wireguard/wg0.conf (see wireguard-README.md for template)
sudo systemctl enable --now wg-quick@wg0

# Verify
ping 10.10.10.1   # Proxmox host
```

### Windows

1. Download and install the [WireGuard app](https://www.wireguard.com/install/)
2. Open WireGuard → **Add Tunnel** → **Add empty tunnel**
3. Copy the generated public key — register it as a peer (see wireguard-README.md)
4. Paste the full client config, click **Activate**

### macOS / Android / iOS

Import the config file into the WireGuard app. The config template is in [`ansible/playbooks/wireguard-README.md`](ansible/playbooks/wireguard-README.md).

**Split tunnel:** only homelab traffic routes through the VPN (10.10.10.0/24, 10.10.1.0/24, 10.10.2.0/24). Internet traffic goes direct.

---

## Full Rebuild from Bare Metal

### 1. Install Proxmox

Boot the Proxmox VE ISO. During install:
- Disk: SSD (ZFS, single disk)
- Hostname: `homelab`
- IP: 192.168.1.10/24, gateway 192.168.1.1
- Timezone: Europe/Zurich

### 2. Restore ZFS data from HDD backup

SSH into the freshly installed host as `root`:

```bash
# Import HDD pool
zpool import hdd

# Restore VM disks
zfs receive -F rpool/data < <(syncoid hdd/backups/rpool-data rpool/data)

# Restore Proxmox OS datasets (optional — only if SSD was lost)
zfs receive -F rpool/ROOT/pve-1 < <(syncoid hdd/backups/pve-root rpool/ROOT/pve-1)
```

Or use syncoid directly for incremental restore:
```bash
syncoid --recursive hdd/backups/rpool-data rpool/data
```

### 3. Configure Proxmox host via Ansible

On first run, the playbook connects as `root` (before hardening):

```bash
cd ansible
ansible-playbook playbooks/host.yml
```

This creates `adyrem`, hardens SSH (port 2222, no root login), sets up the `claude-code` SFTP user, WireGuard, and DuckDNS. Root SSH access ends after this run.

Subsequent runs use `adyrem` (already set in `group_vars/proxmox_hosts/vars.yml`).

### 4. Configure network and firewall

Edit `/etc/network/interfaces` on Proxmox to restore the DNAT rules (port 80/443 → Traefik, port 53 → Pi-hole). Template is tracked at `proxmox/network-interfaces`.

Apply host firewall rules:
```bash
ansible-playbook playbooks/host.yml
```

### 5. Start infrastructure VMs/CTs and run playbooks

```bash
# Start VMs (or they start automatically if autostart was set)
# Run infra playbooks
cd ansible
ansible-playbook playbooks/pihole.yml
ansible-playbook playbooks/traefik.yml
ansible-playbook playbooks/gitea.yml
ansible-playbook playbooks/monitoring.yml
ansible-playbook playbooks/claude-code-vm.yml
```

### 6. Set up sanoid/syncoid for ZFS snapshots

Handled automatically by `playbooks/host.yml` (the `sanoid` role). No manual steps needed.

### 7. Restore Grafana password

Grafana bootstraps with password `admin`. Log in at `http://10.10.1.137:3000` and change it when prompted.

### 8. Reconfigure Internet-Box

- Port forward UDP 51820 → 192.168.1.10 (WireGuard)
- Port forward TCP 80 → 192.168.1.10 (Let's Encrypt HTTP-01)
- Port forward TCP 443 → 192.168.1.10 (HTTPS)

---

## Restore a VM from ZFS Snapshot

List available snapshots:
```bash
zfs list -t snapshot -r rpool/data
```

Roll back a VM disk to a snapshot:
```bash
# Stop the VM first (e.g., VM 100)
qm stop 100

# Roll back to snapshot
zfs rollback rpool/data/vm-100-disk-0@autosnap_2026-05-15_00:00:00_daily

# Start the VM
qm start 100
```

Restore a VM from the HDD backup pool (e.g., after SSD failure):
```bash
zfs send hdd/backups/rpool-data/vm-100-disk-0@<snapshot> | zfs receive rpool/data/vm-100-disk-0
```

---

## Provisioning a New Dev VM

Dev VMs run on `vmbr2` (10.10.2.0/24) so Claude Code has no path to infra.

1. Create the VM in the Proxmox UI (or clone an existing one). Assign a static IP on `vmbr2`.
2. Add it to the inventory:

```ini
# ansible/inventory/hosts.yml
dev_vms:
  hosts:
    my-new-vm:
      ansible_host: 10.10.2.X
```

3. Run the base playbook:
```bash
ansible-playbook playbooks/site.yml --limit my-new-vm
```

4. Add an SSH alias in `~/.ssh/config` and in `ansible/roles/claude_code/templates/ssh_config.j2`, then re-run `ansible-playbook playbooks/claude-code-vm.yml`.

---

## Adding a New VM to Monitoring

Node Exporter and Promtail are installed by `site.yml` on all Arch VMs automatically.

For the VM to appear in Prometheus, add it to the scrape config in `ansible/roles/monitoring/templates/prometheus.yml.j2` under the appropriate job, then re-run:

```bash
ansible-playbook playbooks/monitoring.yml
```

Grafana dashboards are provisioned automatically from the datasource. For custom dashboards, export the JSON from Grafana UI and save to `files/grafana-dashboards/`.

---

## Secrets Management

Secrets are encrypted with `ansible-vault`. The vault password lives at `~/.config/homelab/vault_pass` (never committed).

```bash
# Encrypt a new secret
ansible-vault encrypt_string 'mysecret' --name 'vault_my_var'

# Edit an existing vault file
ansible-vault edit ansible/inventory/group_vars/all/vault.yml

# Run a playbook with vault
ansible-playbook playbooks/gitea.yml  # picks up vault_pass from env var set above
```
