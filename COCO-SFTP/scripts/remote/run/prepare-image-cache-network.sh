#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../install" && pwd)/remote-install-common.sh"

require_root
require_cmd ip
require_cmd iptables
require_cmd modprobe

IMAGE_CACHE_NET="${COCO_NERDCTL_NET:-coco-bridge}"
IMAGE_CACHE_DNS="${COCO_NERDCTL_DNS:-192.168.31.1}"
IMAGE_CACHE_BRIDGE="${COCO_IMAGE_CACHE_BRIDGE:-coco0}"
IMAGE_CACHE_SUBNET="${COCO_IMAGE_CACHE_SUBNET:-10.88.0.0/16}"

for module in overlay vsock vhost-vsock loop; do
    modprobe "$module" || log_install "warning: failed to load module $module"
done

"$COCO_ROOT/scripts/remote/install/install-cni.sh"

if ip link show "$IMAGE_CACHE_BRIDGE" >/dev/null 2>&1; then
    ip link set "$IMAGE_CACHE_BRIDGE" up || true
fi

sysctl -w net.ipv4.ip_forward=1 >/dev/null
if ! iptables -t nat -C POSTROUTING -s "$IMAGE_CACHE_SUBNET" ! -o "$IMAGE_CACHE_BRIDGE" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "$IMAGE_CACHE_SUBNET" ! -o "$IMAGE_CACHE_BRIDGE" -j MASQUERADE
fi

log_install "prepared verified image-cache network: net=$IMAGE_CACHE_NET dns=$IMAGE_CACHE_DNS bridge=$IMAGE_CACHE_BRIDGE subnet=$IMAGE_CACHE_SUBNET"
