#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# setup-arch-vm.sh
# Creates a minimal Arch Linux VM on the local Fedora host using KVM/libvirt.
# VM disk images are stored under homelab/vms/.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_DIR="$PROJECT_DIR/vms"
ISO_DIR="$VM_DIR/iso"

VM_NAME="arch-base"
VM_DISK="$VM_DIR/${VM_NAME}.qcow2"
VM_RAM=2048        # MiB
VM_CPUS=2
VM_DISK_SIZE=20    # GiB

ARCH_ISO_URL="https://geo.mirror.pkgbuild.com/iso/2026.04.01/archlinux-2026.04.01-x86_64.iso"
ARCH_ISO_SHA256="f14bf46afbe782d28835aed99bfa2fe447903872cb9f4b21153196d6ed1d48ae"
ARCH_ISO="$ISO_DIR/archlinux-2026.04.01-x86_64.iso"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m  ✓\033[0m $*"; }
warn()  { echo -e "\033[1;33m  !\033[0m $*"; }
die()   { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

require_cmd() { command -v "$1" &>/dev/null || die "'$1' not found. Install it and re-run."; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
info "Running pre-flight checks..."

require_cmd virsh
require_cmd virt-install
require_cmd qemu-img
require_cmd sha256sum

# KVM modules — load if not already present
if ! lsmod | grep -q '^kvm'; then
    info "KVM modules not loaded — attempting to load..."
    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        sudo modprobe kvm_intel || die "Failed to load kvm_intel. Enable virtualisation in BIOS/UEFI."
    else
        sudo modprobe kvm_amd || die "Failed to load kvm_amd. Enable virtualisation in BIOS/UEFI."
    fi
fi
ok "KVM modules loaded"

# br_netfilter — required for virtnetworkd to configure bridge netfilter rules;
# without it /proc/sys/net/bridge/ doesn't exist and net-start fails with EPERM
if ! lsmod | grep -q '^br_netfilter'; then
    info "Loading br_netfilter module..."
    sudo modprobe br_netfilter || die "Failed to load br_netfilter kernel module."
fi
# Persist across reboots
if [[ ! -f /etc/modules-load.d/libvirt.conf ]]; then
    echo -e "kvm_intel\nbr_netfilter" | sudo tee /etc/modules-load.d/libvirt.conf >/dev/null
fi
ok "br_netfilter loaded"

# libvirt daemons — Fedora uses modular socket-activated daemons, not monolithic libvirtd
LIBVIRT_SOCKETS=(virtqemud virtnetworkd virtnodedevd virtstoraged virtsecretd)
info "Enabling libvirt modular daemons..."
for svc in "${LIBVIRT_SOCKETS[@]}"; do
    if ! systemctl is-active --quiet "${svc}.socket"; then
        sudo systemctl enable --now "${svc}.socket"
    fi
    # Remove the idle timeout so daemons don't shut down mid-operation
    if [[ ! -f /etc/systemd/system/${svc}.service.d/notimeout.conf ]]; then
        sudo mkdir -p "/etc/systemd/system/${svc}.service.d"
        printf '[Service]\nEnvironment=%s_ARGS=\n' "${svc^^}" \
            | sudo tee "/etc/systemd/system/${svc}.service.d/notimeout.conf" >/dev/null
    fi
    if ! systemctl is-active --quiet "${svc}.service"; then
        sudo systemctl start "${svc}.service" 2>/dev/null || true
    fi
done
sudo systemctl daemon-reload
ok "libvirt modular daemons ready"

# Group membership — required for polkit to allow bridge/network operations
if ! id -nG | grep -qw libvirt; then
    info "Adding $USER to libvirt and kvm groups..."
    sudo usermod -aG libvirt,kvm "$USER"
    echo
    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │  Group membership updated. You must start a new shell   │"
    echo "  │  for the change to take effect, then re-run the script. │"
    echo "  │                                                          │"
    echo "  │  Run:  newgrp libvirt                                    │"
    echo "  │  Then: ./scripts/setup-arch-vm.sh                       │"
    echo "  └─────────────────────────────────────────────────────────┘"
    exit 0
fi
ok "User is in libvirt group"
VIRSH="virsh --connect qemu:///system"
VIRT_INSTALL="virt-install --connect qemu:///system"
QEMU_IMG="qemu-img"

# ---------------------------------------------------------------------------
# Default network
# ---------------------------------------------------------------------------
info "Checking libvirt default network..."
if ! $VIRSH net-list --all | grep -q 'default'; then
    info "Default network not defined — creating it..."
    $VIRSH net-define /usr/share/libvirt/networks/default.xml \
        || die "Could not define default network. Is libvirt-daemon-config-network installed?"
fi
if ! $VIRSH net-list | grep -q 'default'; then
    # Remove a stale virbr0 left over from a previous failed start
    if ip link show virbr0 &>/dev/null; then
        info "Removing stale virbr0 bridge..."
        sudo ip link set virbr0 down 2>/dev/null || true
        sudo ip link delete virbr0 2>/dev/null || true
    fi
    $VIRSH net-start default || true   # ignore "already active" race
    ok "Default network started"
fi
$VIRSH net-autostart default &>/dev/null || true
ok "Default network ready"

# ---------------------------------------------------------------------------
# Directory setup
# ---------------------------------------------------------------------------
info "Creating VM storage directories..."
mkdir -p "$VM_DIR" "$ISO_DIR"

# Grant the qemu user search (execute) permission on every directory component
# leading to the VM storage — QEMU runs as uid qemu and can't traverse home dirs.
if command -v setfacl &>/dev/null; then
    dir="$VM_DIR"
    while [[ "$dir" != "/" ]]; do
        setfacl -m u:qemu:x "$dir" 2>/dev/null || sudo setfacl -m u:qemu:x "$dir"
        dir="$(dirname "$dir")"
    done
    # Also allow qemu to read/write inside the vms directory itself
    setfacl -m u:qemu:rwx "$VM_DIR" 2>/dev/null || sudo setfacl -m u:qemu:rwx "$VM_DIR"
    setfacl -m u:qemu:rx  "$ISO_DIR" 2>/dev/null || sudo setfacl -m u:qemu:rx  "$ISO_DIR"
else
    warn "setfacl not found — install 'acl' package if QEMU reports permission denied."
fi
ok "Directories ready: $VM_DIR"

# ---------------------------------------------------------------------------
# ISO download
# ---------------------------------------------------------------------------
if [[ -f "$ARCH_ISO" ]]; then
    info "ISO already present — verifying checksum..."
    echo "$ARCH_ISO_SHA256  $ARCH_ISO" | sha256sum --check --quiet \
        && ok "Checksum OK" \
        || { warn "Checksum mismatch — re-downloading ISO..."; rm -f "$ARCH_ISO"; }
fi

if [[ ! -f "$ARCH_ISO" ]]; then
    info "Downloading Arch Linux ISO (~1.1 GB)..."
    curl -L --progress-bar -o "$ARCH_ISO" "$ARCH_ISO_URL"
    info "Verifying checksum..."
    echo "$ARCH_ISO_SHA256  $ARCH_ISO" | sha256sum --check --quiet \
        || die "ISO checksum verification failed. File may be corrupt."
    ok "ISO downloaded and verified"
fi

# ---------------------------------------------------------------------------
# VM disk image
# ---------------------------------------------------------------------------
if [[ -f "$VM_DISK" ]]; then
    warn "Disk image already exists at $VM_DISK"
    read -rp "  Delete and recreate? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborting — existing disk left intact."
    rm -f "$VM_DISK"
fi

info "Creating ${VM_DISK_SIZE}G qcow2 disk image..."
$QEMU_IMG create -f qcow2 "$VM_DISK" "${VM_DISK_SIZE}G" -q
ok "Disk image created: $VM_DISK"

# ---------------------------------------------------------------------------
# VM definition
# ---------------------------------------------------------------------------
if $VIRSH dominfo "$VM_NAME" &>/dev/null; then
    warn "VM '$VM_NAME' already defined in libvirt."
    read -rp "  Undefine and recreate? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborting — existing VM left intact."
    $VIRSH destroy "$VM_NAME" 2>/dev/null || true
    $VIRSH undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
fi

# Verify virbr0 is actually up — virtnetworkd may have timed out and torn it down
if ! ip link show virbr0 &>/dev/null; then
    info "virbr0 is gone — restarting default network..."
    sudo systemctl restart virtnetworkd.service
    sleep 2
    $VIRSH net-start default 2>/dev/null || true
    ip link show virbr0 &>/dev/null || die "virbr0 still missing after restart — check virtnetworkd logs."
fi

OVMF_CODE="/usr/share/edk2/ovmf/OVMF_CODE.fd"
OVMF_VARS="/usr/share/edk2/ovmf/OVMF_VARS.fd"

info "Defining VM '$VM_NAME'..."
$VIRT_INSTALL \
    --name "$VM_NAME" \
    --ram "$VM_RAM" \
    --vcpus "$VM_CPUS" \
    --cpu host-passthrough \
    --os-variant archlinux \
    --disk "path=$VM_DISK,format=qcow2,bus=virtio,cache=writeback" \
    --disk "path=$ARCH_ISO,device=cdrom,readonly=on,bus=sata" \
    --network network=default,model=virtio \
    --graphics spice,listen=127.0.0.1 \
    --video qxl \
    --boot "loader=${OVMF_CODE},loader.readonly=yes,loader.type=pflash,nvram.template=${OVMF_VARS},cdrom,hd" \
    --noautoconsole

ok "VM '$VM_NAME' defined and started"

# ---------------------------------------------------------------------------
# Get VM IP (may take a moment for DHCP)
# ---------------------------------------------------------------------------
info "Waiting for VM to get a DHCP address (up to 60s)..."
VM_IP=""
for i in $(seq 1 12); do
    sleep 5
    VM_IP=$($VIRSH domifaddr "$VM_NAME" 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || true)
    [[ -n "$VM_IP" ]] && break
    echo -n "."
done
echo

if [[ -n "$VM_IP" ]]; then
    ok "VM IP address: $VM_IP"
else
    warn "Could not detect VM IP yet — it may still be booting."
    warn "Run:  virsh domifaddr $VM_NAME   to check later."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  VM '$VM_NAME' is booting into the Arch Linux live environment."
echo
echo "  Open the console in virt-manager, then run:"
echo
echo "    1. On your host — serve the config (if not already running):"
echo "       cd ~/dev/homelab && python3 -m http.server 8080"
echo
echo "    2. In the VM console — one-liner to fetch config and start install:"
echo "       curl http://192.168.122.1:8080/scripts/vm-install.sh | bash"
echo
echo "    3. After install completes, select Reboot."
echo "       SSH will be available on the installed system:"
if [[ -n "$VM_IP" ]]; then
echo "       ssh -i ~/dev/homelab/keys/homelab_ed25519 adyrem@$VM_IP"
fi
echo
echo "  Arch ISO:   $ARCH_ISO"
echo "  Disk image: $VM_DISK"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
