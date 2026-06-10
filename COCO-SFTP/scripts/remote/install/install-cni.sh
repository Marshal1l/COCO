#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remote-install-common.sh"
require_root
require_dir "$COCO_ROOT/cni/bin"
require_file "$COCO_ROOT/configs/cni/10-coco-bridge.conf"
require_cmd iptables

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

install -m 0644 "$COCO_ROOT/configs/cni/10-coco-bridge.conf" /etc/cni/net.d/10-coco-bridge.conflist
rm -f /etc/cni/net.d/10-coco-bridge.conf

sysctl -w net.ipv4.ip_forward=1 >/dev/null
if ! iptables -t nat -C POSTROUTING -s 10.88.0.0/16 ! -o coco0 -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s 10.88.0.0/16 ! -o coco0 -j MASQUERADE
fi

log_install "installed CNI plugins and configs"
