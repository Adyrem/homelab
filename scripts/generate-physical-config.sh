#!/usr/bin/env bash
# Run in the Arch live environment to generate archinstall-config-physical.json
# with correct partition sizes for the target SSD.
#
# Usage:
#   ./generate-physical-config.sh /dev/sda          # outputs to /tmp/config.json
#   ./generate-physical-config.sh /dev/nvme0n1p0    # NVMe example
set -euo pipefail

info() { echo -e "\033[1;34m==>\033[0m $*"; }
die()  { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

DEVICE="${1:-}"
if [[ -z "$DEVICE" ]]; then
    echo "Usage: $0 <ssd-device>"
    echo
    echo "Available disks:"
    lsblk -d -o NAME,SIZE,MODEL
    exit 1
fi

[[ -b "$DEVICE" ]] || die "Device '$DEVICE' not found or is not a block device."

# ---------------------------------------------------------------------------
# Partition layout
# ---------------------------------------------------------------------------
# Layout:
#   [1 MiB gap] [1 GiB ESP /boot] [rest: BTRFS root with subvolumes]
#
START_PADDING_B=1048576      # 1 MiB
ESP_B=1073741824             # 1 GiB
END_PADDING_B=1048576        # 1 MiB — leave 1 MiB at end for partition table alignment
ROOT_START_B=$(( START_PADDING_B + ESP_B ))   # = 1074790400

DISK_BYTES=$(lsblk -b -d -n -o SIZE "$DEVICE")
ROOT_SIZE_B=$(( DISK_BYTES - ROOT_START_B - END_PADDING_B ))

info "Device:     $DEVICE"
info "Disk size:  $DISK_BYTES bytes ($(( DISK_BYTES / 1024 / 1024 / 1024 )) GiB)"
info "ESP start:  $START_PADDING_B  size: $ESP_B"
info "Root start: $ROOT_START_B  size: $ROOT_SIZE_B"

(( ROOT_SIZE_B > 0 )) || die "Disk is too small to partition."

OUT="/tmp/config.json"

cat > "$OUT" << EOF
{
    "app_config": null,
    "archinstall-language": "English",
    "auth_config": {},
    "bootloader_config": {
        "bootloader": "Systemd-boot",
        "removable": true,
        "uki": false
    },
    "custom_commands": [
        "mkdir -p /home/adyrem/.ssh && chmod 700 /home/adyrem/.ssh && echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILdW4rhQFv561bYs8w0/VgR6AFgOLvVsAh6pcjZ/CO2R homelab' > /home/adyrem/.ssh/authorized_keys && chmod 600 /home/adyrem/.ssh/authorized_keys && chown -R adyrem:adyrem /home/adyrem/.ssh",
        "mkdir -p /vms/infra /vms/dev"
    ],
    "disk_config": {
        "btrfs_options": {
            "snapshot_config": null
        },
        "config_type": "manual_partitioning",
        "device_modifications": [
            {
                "device": "$DEVICE",
                "wipe": true,
                "partitions": [
                    {
                        "btrfs": [],
                        "dev_path": null,
                        "flags": ["boot", "esp"],
                        "fs_type": "fat32",
                        "mount_options": [],
                        "mountpoint": "/boot",
                        "obj_id": "part-esp",
                        "size": {
                            "sector_size": { "unit": "B", "value": 512 },
                            "unit": "GiB",
                            "value": 1
                        },
                        "start": {
                            "sector_size": { "unit": "B", "value": 512 },
                            "unit": "MiB",
                            "value": 1
                        },
                        "status": "create",
                        "type": "primary"
                    },
                    {
                        "btrfs": [
                            { "name": "@",          "mountpoint": "/" },
                            { "name": "@home",      "mountpoint": "/home" },
                            { "name": "@var",       "mountpoint": "/var" },
                            { "name": "@snapshots", "mountpoint": "/.snapshots" },
                            { "name": "@vms-infra", "mountpoint": "/vms/infra" },
                            { "name": "@vms-dev",   "mountpoint": "/vms/dev" }
                        ],
                        "dev_path": null,
                        "flags": [],
                        "fs_type": "btrfs",
                        "mount_options": ["compress=zstd", "noatime"],
                        "mountpoint": null,
                        "obj_id": "part-root",
                        "size": {
                            "sector_size": { "unit": "B", "value": 512 },
                            "unit": "B",
                            "value": $ROOT_SIZE_B
                        },
                        "start": {
                            "sector_size": { "unit": "B", "value": 512 },
                            "unit": "B",
                            "value": $ROOT_START_B
                        },
                        "status": "create",
                        "type": "primary"
                    }
                ]
            }
        ]
    },
    "hostname": "homelab",
    "kernels": ["linux"],
    "locale_config": {
        "kb_layout": "de_CH-latin1",
        "sys_enc": "UTF-8",
        "sys_lang": "en_US"
    },
    "mirror_config": {
        "custom_repositories": [],
        "custom_servers": [],
        "mirror_regions": {
            "Worldwide": ["https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"]
        },
        "optional_repositories": []
    },
    "network_config": {
        "type": "nm"
    },
    "ntp": true,
    "packages": [
        "base-devel",
        "git",
        "openssh",
        "networkmanager",
        "vim",
        "btrbk",
        "nftables"
    ],
    "parallel_downloads": 5,
    "script": "guided",
    "services": ["sshd", "NetworkManager", "nftables"],
    "swap": {
        "algorithm": "zstd",
        "enabled": false
    },
    "timezone": "Europe/Zurich",
    "version": "4.1",
    "users": [
        {
            "enc_password": "\$y\$j9T\$pqMooSvLvxBg2YP7eCQlq/\$Ae8.dvSYB817bQkj5w9S4wu9OtWIq.p/pbWY6A/ythD",
            "groups": ["wheel"],
            "sudo": true,
            "username": "adyrem"
        }
    ]
}
EOF

echo
echo "Config written to $OUT"
echo "Run:  archinstall --config $OUT"
