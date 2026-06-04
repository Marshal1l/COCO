#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/remote-install-common.sh"
require_root

"$SCRIPT_DIR/install-cni.sh"
"$SCRIPT_DIR/install-configs.sh"
"$SCRIPT_DIR/install-guest-pull-snapshotter.sh"
"$SCRIPT_DIR/install-kata.sh"
"$SCRIPT_DIR/install-nerdctl.sh"

log_install "runtime install complete; host kernel and firmware are intentionally out of scope"
log_install "run ./scripts/remote/run/start-container-runtime.sh to restart guest-pull and containerd"
