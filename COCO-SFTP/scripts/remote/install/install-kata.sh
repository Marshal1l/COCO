#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remote-install-common.sh"
require_root
require_file "$COCO_ROOT/kata-bins/kata-runtime"
require_file "$COCO_ROOT/kata-bins/kata-monitor"
require_file "$COCO_ROOT/kata-bins/containerd-shim-kata-v2"

mkdir -p /opt/kata/bin /usr/local/bin

install -m0755 "$COCO_ROOT/kata-bins/kata-runtime" /opt/kata/bin/kata-runtime
install -m0755 "$COCO_ROOT/kata-bins/kata-monitor" /opt/kata/bin/kata-monitor
install -m0755 "$COCO_ROOT/kata-bins/containerd-shim-kata-v2" /usr/local/bin/containerd-shim-kata-v2

ln -sf /opt/kata/bin/kata-runtime /usr/local/bin/kata-runtime
ln -sf /opt/kata/bin/kata-monitor /usr/local/bin/kata-monitor

log_install "installed Kata runtime, monitor, and shim"
