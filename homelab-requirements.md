# Homelab Setup Requirements

## Hardware Context
- Host machine with Intel i7-8700, 32GB RAM
- Two disks: one smaller SSD (primary), one larger WD Black HDD (secondary)
- Complete fresh install, nothing to preserve

---

## Non-Negotiable Requirements

1. Claude Code sessions can SSH into multiple VMs in the same session with full sudo access inside the VM.
2. Claude Code sessions cannot execute any commands on the Proxmox host — only read and write files in designated folders via SFTP.
3. A Windows VM with Visual Studio must be runnable and accessible via RDP.

## Claude Code Execution Model

Claude Code runs inside a **dedicated persistent VM** hosted on Proxmox (not on the Proxmox host directly and not on the operator's local machine). This satisfies requirement 2 by construction — Claude Code never has a shell on the host.

**Why a dedicated VM, not the local machine:**  
The operator connects from multiple devices (home desktop, laptop, etc.) via WireGuard. Running Claude Code on a local machine would lose session state on disconnect. Running it in a persistent VM means sessions survive disconnects — the operator reconnects via SSH and reattaches a `tmux` session.

**Access pattern:**
- Operator → WireGuard → SSH into Claude Code VM → `tmux attach`
- Claude Code VM → SSH into dev/infra VMs (full sudo inside each VM)
- Claude Code VM → SFTP to Proxmox host via `claude-code` user (read/write workspace files only, no shell)
- Claude Code VM has no route to `infra-net` or `desktop-net` — dev VMs only, plus the SFTP path to host

**Session persistence:** `tmux` runs inside the Claude Code VM. Sessions survive SSH disconnects. The operator can reconnect from any WireGuard-connected device and resume exactly where they left off.

---

## 1. Disk Layout

- Proxmox installed on the SSD using ZFS (single-disk pool)
  - ZFS chosen for native snapshots, send/receive, and compression
  - VM disk images stored in a ZFS pool on the SSD (`rpool` or a dedicated dataset)
- HDD formatted as a ZFS pool, used for:
  - Receiving ZFS send/receive snapshots from SSD (local backup)
  - Storage for non-critical / parked VMs
- Snapshot schedule: daily snapshots retained for 7 days, weekly retained for 4 weeks
- Snapshot tooling: `sanoid` (policy-based ZFS snapshots) + `syncoid` (ZFS send/receive to HDD)

---

## 2. Host OS

- **Proxmox VE** (latest stable release, Debian-based)
- Installed via the official Proxmox ISO — no custom OS required
- No desktop environment on the host
- Minimal additional packages — Proxmox manages the hypervisor; everything else runs in VMs
- Locale: `en_US.UTF-8`, keyboard layout: Swiss German, timezone: `Europe/Zurich`
- Hostname: `homelab`
- Automatic security updates: `unattended-upgrades` configured for security patches only; full updates manual
- Proxmox web UI accessible from local network / VPN only

---

## 3. Networking & Remote Access

### SSH
- SSH access to host is **only permitted from within the local network or VPN** — Proxmox firewall blocks SSH from WAN
- Key-based authentication only, password auth disabled
- Root login disabled (admin user only)
- A dedicated SSH keypair for this project; public key committed to repo, private key kept by operator
- Dedicated non-default SSH port — to be decided during setup

### RDP
- RDP is for VMs only — no RDP on the host
- VM RDP accessible through VPN from outside the network

### Firewall
- Proxmox built-in firewall enabled at datacenter and host level
- Default deny inbound from WAN
- Allow inbound from WAN: VPN port only
- Allow inbound from local network / VPN: SSH (host), Proxmox web UI (8006), RDP (VMs), monitoring ports (Grafana, Prometheus)
- VM-level firewall rules managed per VM in Proxmox

### VPN (Internet-Box)
- Internet-Box 3 or 4 — use **IKEv2** (supported on both; WireGuard only on 4+, cannot confirm model)
- VPN server configured on the Internet-Box itself (not on the host)
- DynDNS configured on the Internet-Box for stable external hostname
- All external access (SSH, RDP, Gitea, monitoring dashboards) routes through this VPN
- Document VPN client setup steps for Windows and Linux clients in the repo README

---

## 4. Hypervisor

- **Proxmox VE** — KVM/QEMU managed via Proxmox (not libvirt)
- VM management via Proxmox web UI and `qm` / `pvesh` CLI
- VM networks (Proxmox Linux bridges):
  - `infra-net` (`vmbr1`): isolated NAT for infrastructure VMs (Gitea, monitoring)
  - `dev-net` (`vmbr2`): isolated NAT for Claude Code workload VMs
  - `desktop-net` (`vmbr3`): NAT for desktop VMs
  - No VM has bridged access to the physical LAN unless explicitly required
- UEFI support via OVMF (included in Proxmox)
- TPM 2.0 emulation via `swtpm` (required for Windows 11)
- Infrastructure VMs (Gitea, monitoring) set to autostart on host boot via Proxmox autostart
- VM configs (`.conf` files from `/etc/pve/qemu-server/`) committed to Ansible repo

---

## 5. Users & Permissions

### Host Users
- One admin user (human operator):
  - SSH key login only, no password SSH
  - Full `sudo` access
- One `claude-code` service user — enforces non-negotiable requirement 2:
  - **`ForceCommand internal-sftp`** + **`ChrootDirectory`** in sshd — SFTP-only, zero shell execution on host
  - Chroot restricted to `/home/claude-code` with a writable `workspace/` subdirectory
  - SSH access restricted to a dedicated keypair (private key lives in the Claude Code VM only)
  - No access to Proxmox tooling, VM management, or other users' files
  - Cannot be used as a jump host — `AllowTcpForwarding no`
  - Used exclusively by the Claude Code VM to read/write files on the Proxmox host

### VM Users (all VMs)
- `root` account: password set, SSH login disabled
- `vmuser` account: default non-root user, SSH key login, full sudo inside the VM
- Additional users may be added per VM as needed

---

## 6. Virtual Machines

### 6.1 Gitea VM (Infrastructure)
- **Distro:** Arch Linux minimal (provisioned via `archinstall` JSON config)
- **Purpose:** Self-hosted Git, mirrors all repos to GitHub automatically
- **Setup:** Provisioned manually as bootstrap step — must exist before Ansible automation can run
- **Storage:** SSD ZFS pool (infrastructure-critical)
- **Access:** SSH from host admin user; Gitea web UI accessible from local network / VPN
- **Gitea config:**
  - Admin account set up manually
  - Mirror job configured for every repo to sync to GitHub
  - The Ansible homelab repo is the primary repo hosted here
- **Backups:** Proxmox VM snapshot + ZFS send/receive to HDD; Gitea data directory snapshotted daily

### 6.2 Monitoring VM (Infrastructure)
- **Distro:** Arch Linux minimal
- **Purpose:** Centralised observability for host and all VMs
- **Setup:** Provisioned via Ansible after Gitea bootstrap; autostart on host boot
- **Storage:** SSD ZFS pool (infrastructure-critical)
- **Access:** Grafana web UI accessible from local network / VPN only; no WAN exposure
- **Backups:** Proxmox VM snapshot + ZFS send/receive to HDD

#### Stack
| Component | Role |
|---|---|
| **Prometheus** | Metrics collection and storage |
| **Grafana** | Dashboards and alerting UI |
| **Node Exporter** | Host and VM system metrics (CPU, RAM, disk, network) |
| **Alertmanager** | Alert routing (email or other notification channel) |
| **Loki** | Log aggregation |
| **Promtail** | Log shipping agent (runs on host and each VM) |

#### What Is Monitored
- **Host system:** CPU, RAM, disk usage/IO, network throughput, ZFS pool health, Proxmox VM states
- **All VMs:** CPU, RAM, disk, network via Node Exporter installed in each VM by Ansible
- **Gitea VM:** Service health, disk usage of repo storage
- **Windows VM:** Basic ping/availability check only (no agent)
- **ZFS snapshots:** Alert if daily snapshot has not run within expected window
- **VM availability:** Alert if any infrastructure VM (Gitea, monitoring itself) goes unreachable
- **Disk space:** Alert at 75% and 90% on SSD and HDD ZFS pools

#### Alerting
- Alertmanager configured with at least one notification channel (email recommended as default)
- Alert on: host down, infrastructure VM down, disk >75%, snapshot missed, high CPU/RAM sustained >15 min

#### Ansible Integration
- Node Exporter and Promtail installed and enabled on every Linux VM by the base VM playbook
- Prometheus scrape config updated automatically when a new VM is provisioned
- Monitoring VM definition and Prometheus/Grafana configs committed to Ansible repo
- Grafana dashboards exported as JSON and committed to repo for full reproducibility

### 6.3 Windows VM
- **Purpose:** Visual Studio development (extension building) — non-negotiable requirement 3
- **License:** Activated via personal Microsoft account
- **UEFI + TPM:** OVMF + swtpm for Windows 11 compatibility
- **Resources:** 8 cores, 16GB RAM (adjustable)
- **Storage:** SSD ZFS pool (active use); snapshot to HDD after each milestone
- **Snapshot strategy:** ZFS snapshot of VM disk taken after:
  1. Clean Windows install + activation
  2. Visual Studio install + configuration
  - Snapshots sent to HDD ZFS pool; rebuild = `zfs receive` from HDD
- **Access:** RDP via VPN from outside network
- **Network:** `desktop-net`, no access to host or other VM networks
- **Monitoring:** Ping/availability check only

### 6.4 Fedora KDE VM
- **Purpose:** General purpose Linux desktop
- **Distro:** Fedora (latest stable) with KDE Plasma desktop
- **Resources:** 4 cores, 8GB RAM (adjustable)
- **Storage:** HDD ZFS pool (non-critical)
- **Users:** `root` + `vmuser`
- **Access:** RDP via `xrdp` or VNC; SSH
- **Network:** `desktop-net`
- **Monitoring:** Node Exporter + Promtail installed via Ansible

### 6.5 Arch Desktop VM
- **Purpose:** General purpose Linux desktop
- **Distro:** Arch Linux with desktop environment (to be chosen at setup time)
- **Resources:** 4 cores, 8GB RAM (adjustable)
- **Storage:** HDD ZFS pool (non-critical)
- **Users:** `root` + `vmuser`
- **Access:** RDP or VNC; SSH
- **Network:** `desktop-net`
- **Monitoring:** Node Exporter + Promtail installed via Ansible

### 6.6 Claude Code Dev VMs
- **Purpose:** Isolated environments for Claude Code to operate in — enforces non-negotiable requirement 1
- **Distro:** Arch Linux minimal (provisioned via `archinstall` JSON config)
- **Provisioning:** Cloned from a base template VM, then configured via Ansible
- **Persistence:** VMs are persistent (not ephemeral per session)
- **Multi-VM sessions:** Claude Code may SSH into multiple dev VMs in one session
- **Isolation requirements:**
  - No shared folders with host
  - No access to `infra-net` or `desktop-net`
  - Operates on `dev-net` only
  - No route to host system
  - `vmuser` is the SSH target for Claude Code with full sudo inside the VM
- **Resources:** 2 cores, 4GB RAM per VM (adjustable)
- **Storage:** SSD ZFS pool for active VMs, HDD ZFS pool for parked/unused ones
- **Monitoring:** Node Exporter + Promtail installed via Ansible base VM playbook

---

## 7. Ansible Automation

- All post-install configuration managed via Ansible playbooks
- Repo hosted on Gitea VM, mirrored to GitHub
- Secrets managed via `ansible-vault`; vault password stored only by the operator
- **Playbook structure:**
  ```
  homelab/
  ├── archinstall-config.json          # reproducible base config for Linux guest VMs
  ├── inventory.ini                    # host + VM inventory
  ├── playbooks/
  │   ├── host.yml                     # Proxmox host: users, SSH, firewall, sanoid/syncoid
  │   ├── snapshots.yml                # ZFS snapshot schedules (sanoid) + send/receive (syncoid)
  │   ├── users.yml                    # host users, SSH keys, claude-code SFTP restriction
  │   ├── monitoring.yml               # monitoring VM, Prometheus, Grafana, Loki
  │   └── vms/
  │       ├── gitea.yml
  │       ├── windows.yml
  │       ├── fedora-kde.yml
  │       ├── arch-desktop.yml
  │       └── dev-template.yml
  ├── templates/                       # Jinja2 config templates
  │   ├── prometheus.yml.j2
  │   ├── promtail.yml.j2
  │   ├── alertmanager.yml.j2
  │   └── sanoid.conf.j2
  ├── files/
  │   └── grafana-dashboards/          # exported dashboard JSON files
  ├── vars/
  │   └── vault.yml                    # encrypted secrets
  └── README.md
  ```
- Every playbook must be idempotent (safe to re-run)
- README must document:
  - Full rebuild procedure from bare metal
  - VPN client setup (Windows + Linux)
  - How to provision a new dev VM
  - How to restore a VM from ZFS snapshot
  - How to access the Proxmox web UI and Grafana dashboard
  - How to add a new VM to monitoring

---

## 8. Backup & Recovery

- **Primary backup mechanism:** `syncoid` ZFS send/receive from SSD pool to HDD pool
- **Snapshot policy:** managed by `sanoid` on both pools
- **Scope of backups:**
  - All VM disks on SSD ZFS pool (daily incremental send/receive to HDD)
  - Gitea data directory (daily snapshot)
  - Monitoring VM data directory including Prometheus data (daily snapshot)
  - Grafana dashboards as JSON in git repo (always up to date)
  - Windows VM disk snapshot after each milestone (stored on HDD ZFS pool)
- **No external/cloud backup initially** — architecture must make it easy to add (e.g. `restic` to Backblaze B2) later
- **Recovery procedure documented in README**

---

## 9. Rebuild Order (Disaster Recovery Sequence)

In the event of full hardware loss, the rebuild order is:

1. Install Proxmox on new hardware (ISO installer, ~10 min)
2. Restore SSD ZFS pool from HDD send/receive backups (`zfs receive`)
3. Run `host.yml` Ansible playbook (cloned from GitHub mirror) to configure host users, SSH, firewall
4. Start Gitea VM (restored from ZFS snapshot) and clone Ansible repo from it
5. Run `monitoring.yml` to restore monitoring VM
6. Run remaining playbooks to restore all VMs
7. Import Grafana dashboards from JSON files in repo
8. Reconfigure Internet-Box VPN and DynDNS if hardware changed

---

## 10. Out of Scope (for now)

- External/cloud backups (architecture must not preclude adding later)
- Additional VM distros beyond those listed — template mechanism should make adding easy
- Monitoring of Windows internals beyond availability ping
