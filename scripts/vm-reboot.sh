#!/usr/bin/env bash
set -euo pipefail

VM_NAME="arch-base"

virsh --connect qemu:///system change-media "$VM_NAME" sda --eject 2>/dev/null && echo "ISO ejected" || echo "No ISO to eject"
virsh --connect qemu:///system reboot "$VM_NAME"
echo "Rebooting $VM_NAME..."
