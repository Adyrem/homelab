#!/usr/bin/env bash
# Run this inside the Arch live environment to fetch the config and start archinstall.
# Usage: curl http://192.168.122.1:8080/scripts/vm-install.sh | bash
set -euo pipefail

HOST="http://192.168.122.1:8080"

echo "==> Fetching archinstall config..."
curl -fsSL "$HOST/archinstall-config.json" -o /tmp/config.json

echo "==> Starting archinstall..."
archinstall --config /tmp/config.json
