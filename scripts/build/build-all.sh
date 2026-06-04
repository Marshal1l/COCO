#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: $0

Build the source-backed CoCo runtime stack, inject guest-components into the
local Kata image, refresh the COCO-SFTP manifest, and verify the deployable tree.

This runtime build intentionally excludes OpenCCA firmware and the remote host
kernel. Add board-specific firmware/kernel scripts separately when needed.

For selective builds, use:
  $SCRIPT_DIR/../run/coco-local-flow.sh --build --skip NAME
  $SCRIPT_DIR/../run/coco-local-flow.sh --component NAME
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ "$#" -ne 0 ]]; then
    usage >&2
    exit 2
fi

"$SCRIPT_DIR/build-firecracker.sh"
"$SCRIPT_DIR/build-linux-image-share.sh"
"$SCRIPT_DIR/build-kata-containers.sh"
"$SCRIPT_DIR/build-guest-pull-snapshotter.sh"
"$SCRIPT_DIR/build-guest-components.sh"
"$SCRIPT_DIR/../image/install-guest-components-into-kata-image.sh" --install-if-missing
"$SCRIPT_DIR/../package/prepare-coco-sftp.sh"
"$SCRIPT_DIR/../package/check-coco-sftp.sh"
"$SCRIPT_DIR/../package/check-remote-install-flow.sh"
