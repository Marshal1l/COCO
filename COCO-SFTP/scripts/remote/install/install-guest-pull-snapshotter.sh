#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remote-install-common.sh"
require_root
require_file "$COCO_ROOT/guest-pull/containerd-guest-pull-grpc"
require_file "$COCO_ROOT/guest-pull/guest-pull-overlayfs"

mkdir -p /run/containerd-guest-pull-grpc /etc/containerd-guest-pull-grpc
install -m0755 "$COCO_ROOT/guest-pull/containerd-guest-pull-grpc" /usr/local/bin/containerd-guest-pull-grpc
install -m0755 "$COCO_ROOT/guest-pull/guest-pull-overlayfs" /usr/local/bin/guest-pull-overlayfs

cat > /etc/containerd-guest-pull-grpc/config.toml <<'EOF'
# Guest-pull snapshotter defaults are compiled into containerd-guest-pull-grpc.
# This file exists as the semantic remote configuration anchor.
address = "/run/containerd-guest-pull-grpc/containerd-guest-pull-grpc.sock"
root = "/var/lib/containerd/io.containerd.snapshotter.v1.guest-pull"
image_service_address = "/run/containerd/containerd.sock"
EOF

cat > /etc/systemd/system/guest-pull-snapshotter.service <<'EOF'
[Unit]
Description=Guest-pull snapshotter
After=network.target local-fs.target
Before=containerd.service

[Service]
Type=simple
RuntimeDirectory=containerd-guest-pull-grpc
RuntimeDirectoryMode=0700
ExecStart=/usr/local/bin/containerd-guest-pull-grpc
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable guest-pull-snapshotter

if [[ "${START_GUEST_PULL:-0}" == "1" ]]; then
    systemctl restart guest-pull-snapshotter
fi
log_install "installed guest-pull snapshotter service"
