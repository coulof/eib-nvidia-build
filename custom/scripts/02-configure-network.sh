#!/bin/bash
# Reads the Metal3 config-2 partition (written by Ironic from spec.networkData
# and the BareMetalHost metadata) and applies the per-node network configuration
# using NM Configurator. Runs at first boot via combustion (EIB auto-bundles
# everything in custom/scripts/).
#
# Ref: https://documentation.suse.com/suse-edge/3.5/html/edge/quickstart-metal3.html
set -euo pipefail

CONFIG_DRIVE=$(blkid --label config-2 || true)
if [ -z "$CONFIG_DRIVE" ]; then
    echo "02-configure-network: no config-2 partition, skipping"
    exit 0
fi

MOUNT_DIR=$(mktemp -d)
mount -o ro "$CONFIG_DRIVE" "$MOUNT_DIR"
trap "umount '$MOUNT_DIR' && rm -rf '$MOUNT_DIR'" EXIT

META_DATA="$MOUNT_DIR/openstack/latest/meta_data.json"
NETWORK_DATA="$MOUNT_DIR/openstack/latest/network_data.json"

if [ -f "$META_DATA" ]; then
    HOSTNAME=$(jq -r '."metal3-name" // .hostname // empty' "$META_DATA")
    if [ -n "$HOSTNAME" ]; then
        echo "$HOSTNAME" > /etc/hostname
    fi
fi

if [ ! -f "$NETWORK_DATA" ]; then
    echo "02-configure-network: no network_data.json, skipping nmc"
    exit 0
fi

NMC_DIR=$(mktemp -d)
mkdir -p "$NMC_DIR/desired" "$NMC_DIR/generated"
cp "$NETWORK_DATA" "$NMC_DIR/desired/_all.yaml"

nmc generate --config-dir "$NMC_DIR/desired" --output-dir "$NMC_DIR/generated"
nmc apply --config-dir "$NMC_DIR/generated"

rm -rf "$NMC_DIR"
