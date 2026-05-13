#!/usr/bin/env bash
# Run this inside the Arch live environment on physical hardware.
# Fetches the config generator from the host HTTP server, generates the config
# for the correct SSD device, then starts archinstall.
#
# Usage:
#   curl http://<host-ip>:8080/scripts/physical-install.sh | bash
#   or with device override:
#   curl http://<host-ip>:8080/scripts/physical-install.sh -o /tmp/install.sh
#   bash /tmp/install.sh /dev/sda
set -euo pipefail

HOST="${HOST:-http://192.168.1.1:8080}"   # update to your host's LAN IP
DEVICE="${1:-}"

echo "==> Available disks:"
lsblk -d -o NAME,SIZE,MODEL
echo

if [[ -z "$DEVICE" ]]; then
    read -rp "Enter SSD device for OS install (e.g. /dev/sda): " DEVICE
fi

echo "==> Fetching config generator..."
curl -fsSL "$HOST/scripts/generate-physical-config.sh" -o /tmp/generate-config.sh
chmod +x /tmp/generate-config.sh

echo "==> Generating config for $DEVICE..."
/tmp/generate-config.sh "$DEVICE"

echo "==> Starting archinstall..."
archinstall --config /tmp/config.json
