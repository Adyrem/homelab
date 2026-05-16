# host.yml — Proxmox Host Playbook

Configures the Proxmox host (`192.168.1.10`) with:

- Admin user (`adyrem`) with SSH key auth and passwordless sudo
- `claude-code` SFTP-only user, chrooted to `/home/claude-code/workspace`
- SSH hardened: key-only auth, root login disabled, port changed to 2222
- Unattended security upgrades (Debian security channel only)

---

## Prerequisites

- Proxmox is freshly installed and accessible as `root` via SSH on port 22
- Ansible is installed on the machine running the playbook
- Vault password is at `~/.config/homelab/vault_pass`
- Repo is cloned and you're in the `ansible/` directory

---

## First run (bootstrap)

The first run connects as `root` because `adyrem` doesn't exist yet.
`group_vars/proxmox_hosts/vars.yml` is already set for this — no changes needed.

```bash
ansible-playbook playbooks/host.yml
```

What happens:
1. Creates `adyrem` with your SSH key and passwordless sudo
2. Creates `claude-code` user with SFTP-only access
3. Changes SSH port to 2222 and disables root login
4. Restarts sshd — **root SSH access ends here**

---

## After the first run

Update `inventory/group_vars/proxmox_hosts/vars.yml` to connect as `adyrem`:

```yaml
ansible_user: adyrem
ansible_become: true
ansible_become_method: sudo
ansible_port: 2222
```

Verify you can still connect before relying on this:

```bash
ssh -p 2222 adyrem@192.168.1.10
```

All subsequent runs use:

```bash
ansible-playbook playbooks/host.yml
```

---

## claude-code SFTP access

The `claude-code` user can only SFTP into `/home/claude-code/workspace`. No shell, no TCP forwarding, no escape from the chroot.

From the Claude Code VM:

```bash
sftp -P 2222 claude-code@192.168.1.10
# lands in /workspace (which is /home/claude-code/workspace on the host)
```

The private key for this user lives in the Claude Code VM at `~/.ssh/claude-code_ed25519`.
The corresponding public key is committed at `keys/claude-code_ed25519.pub`.

---

## Re-running safely

The playbook is idempotent. Re-running it after the group_vars update will:
- Ensure all config is still correct
- Apply any template changes (sshd drop-in, unattended-upgrades)
- Restart sshd only if the config changed
