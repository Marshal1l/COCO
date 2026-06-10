#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../install" && pwd)/remote-install-common.sh"

require_root
require_cmd systemctl
require_cmd containerd
require_file /etc/containerd/config.toml
require_file /usr/local/bin/containerd-guest-pull-grpc
require_file /etc/systemd/system/guest-pull-snapshotter.service

"$COCO_ROOT/scripts/remote/run/prepare-image-cache-network.sh"

mkdir -p /etc/systemd/system/containerd.service.d
cat > /etc/systemd/system/containerd.service.d/opencca-nofile.conf <<'EOF'
[Service]
LimitNOFILE=2048
EOF

systemctl daemon-reload
systemctl restart guest-pull-snapshotter
systemctl restart containerd
systemctl is-active --quiet guest-pull-snapshotter
systemctl is-active --quiet containerd

log_install "guest-pull-snapshotter and containerd are active"
