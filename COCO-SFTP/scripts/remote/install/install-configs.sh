#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remote-install-common.sh"
require_root
KATA_CONFIG="${KATA_CONFIG:-configuration-fc.toml}"
require_file "$COCO_ROOT/configs/containerd/config.toml"
require_file "$COCO_ROOT/configs/kata-containers/$KATA_CONFIG"

mkdir -p /etc/containerd /etc/kata-containers /opt/kata/share/defaults/kata-containers
cp "$COCO_ROOT/configs/containerd/config.toml" /etc/containerd/config.toml
cp "$COCO_ROOT/configs/kata-containers/$KATA_CONFIG" /etc/kata-containers/configuration.toml
cp "$COCO_ROOT/configs/kata-containers/$KATA_CONFIG" /opt/kata/share/defaults/kata-containers/configuration.toml

if [[ -f "$COCO_ROOT/configs/kata-containers/configuration-qemu.toml" ]]; then
    cp "$COCO_ROOT/configs/kata-containers/configuration-qemu.toml" /etc/kata-containers/configuration-qemu.toml
fi
log_install "installed containerd and Kata configs"
