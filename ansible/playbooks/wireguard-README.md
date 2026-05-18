# Adding a new WireGuard client

## Current peer assignments

| Name   | IP           |
|--------|--------------|
| server | 10.10.10.1   |
| fedora | 10.10.10.2   |
| phone  | 10.10.10.3   |

Pick the next free IP (10.10.10.3, 10.10.10.4, …) for each new machine.

---

## Step 1 — Generate a keypair on the new machine

**Linux / macOS:**
```bash
wg genkey | tee ~/wg-client.key | wg pubkey
```

**Windows** (WireGuard app installed):
Open the WireGuard app → Add Tunnel → Add empty tunnel. It generates a keypair and shows the public key at the top.

Copy the **public key** — you need it in Step 2.  
Keep the **private key** local. Never commit it to git.

---

## Step 2 — Register the peer in Ansible

Edit `ansible/inventory/group_vars/proxmox_hosts/vars.yml` and add an entry to `wireguard_peers`:

```yaml
wireguard_peers:
  - name: fedora
    public_key: "ivtchk9pxEwYwusMzmn7Uq89LFV3uB1I8iYto0EJuy4="
    allowed_ips: 10.10.10.2/32
  - name: my-new-machine          # ← add this
    public_key: "<public key from Step 1>"
    allowed_ips: 10.10.10.X/32   # ← next free IP
```

---

## Step 3 — Push the peer to the server

```bash
cd ansible && ansible-playbook playbooks/host.yml
```

The server will accept connections from the new client immediately after this.

---

## Step 4 — Create the client config

Use the template below. Store it in a location that is **not** committed to git.

```ini
[Interface]
Address = 10.10.10.X/32
PrivateKey = <private key from Step 1>
DNS = 10.10.1.2

[Peer]
PublicKey = UJaAvoT65+qC7NdD4lKFK+/J1OxKBYp1ZY3ynHjqcHE=
Endpoint = adyrem.duckdns.org:51820
AllowedIPs = 10.10.10.0/24, 10.10.1.0/24, 10.10.2.0/24
PersistentKeepalive = 25
```

`AllowedIPs` is a split tunnel — only homelab traffic goes through the VPN.  
Replace `adyrem.duckdns.org` with `192.168.1.10` when connecting from inside the LAN.

---

## Step 5 — Connect

**Linux (one-off):**
```bash
sudo wg-quick up /path/to/wg0.conf
# disconnect: sudo wg-quick down /path/to/wg0.conf
```

**Linux (persistent, starts on boot):**
```bash
sudo cp wg0.conf /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
```

**Windows / macOS / Android / iOS:**
Import the config file into the WireGuard app, then toggle the tunnel on.

---

## Step 6 — Verify

```bash
ping 10.10.10.1        # Proxmox host
ping 10.10.1.137       # monitoring VM
# Proxmox web UI: https://10.10.10.1:8006
# Grafana:        http://10.10.1.137:3000
```

---

## Removing a client

1. Delete the peer entry from `wireguard_peers` in `group_vars/proxmox_hosts/vars.yml`
2. Run `ansible-playbook playbooks/host.yml`
3. The client's public key is removed from the server — existing sessions drop immediately
