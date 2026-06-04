#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remote-install-common.sh"
require_root
require_dir "$COCO_ROOT/cni/bin"
require_file "$COCO_ROOT/configs/cni/10-coco-bridge.conf"

plugins=(
    bandwidth
    bridge
    dhcp
    dummy
    firewall
    host-device
    host-local
    ipvlan
    loopback
    macvlan
    portmap
    ptp
    sbr
    static
    tap
    tuning
    vlan
    vrf
)

mkdir -p /opt/cni/bin /etc/cni/net.d
for plugin in "${plugins[@]}"; do
    require_file "$COCO_ROOT/cni/bin/$plugin"
    install -m 0755 "$COCO_ROOT/cni/bin/$plugin" "/opt/cni/bin/$plugin"
done

cp "$COCO_ROOT"/configs/cni/*.conf /etc/cni/net.d/

log_install "installed CNI plugins and configs"
