#!/usr/bin/env bash
# Run this inside the Arch live environment to fetch the config and start archinstall.
# Usage: curl http://192.168.122.1:8080/scripts/vm-install.sh | bash
set -euo pipefail

HOST="http://192.168.122.1:8080"

echo "==> Fetching archinstall config..."
curl -fsSL "$HOST/archinstall-config.json" -o /tmp/config.json

echo "==> Setting the adyrem password..."
read -rsp "Password for adyrem: " PASSWORD < /dev/tty; echo
sed -i "s|CHANGEME|$(openssl passwd -6 -stdin <<< "$PASSWORD")|" /tmp/config.json
unset PASSWORD

echo "==> Starting archinstall..."
archinstall --config /tmp/config.json
