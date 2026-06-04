#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remote-install-common.sh"
require_root
require_file "$COCO_ROOT/nerdctl-bin/nerdctl"
require_file "$COCO_ROOT/nerdctl-bin/containerd-rootless.sh"
require_file "$COCO_ROOT/nerdctl-bin/containerd-rootless-setuptool.sh"

install -m0755 "$COCO_ROOT/nerdctl-bin/nerdctl" /usr/local/bin/nerdctl
install -m0755 "$COCO_ROOT/nerdctl-bin/containerd-rootless.sh" /usr/local/bin/containerd-rootless.sh
install -m0755 "$COCO_ROOT/nerdctl-bin/containerd-rootless-setuptool.sh" /usr/local/bin/containerd-rootless-setuptool.sh
log_install "installed nerdctl and containerd rootless helper scripts"
