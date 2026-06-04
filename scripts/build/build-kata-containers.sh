#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

KATA_DIR="${KATA_DIR:-$COCO_ROOT_DIR/kata-containers-cca}"
RUNTIME_DIR="$KATA_DIR/src/runtime"
DEST_DIR="${DEST_DIR:-$COCO_SFTP_ROOT/kata-bins}"
KATA_CC="${KATA_CC:-$COCO_GNU_CC}"

coco_require_cmd make go install "$KATA_CC"
coco_ensure_dir "$DEST_DIR"

coco_log "building Kata runtime host components for linux/$COCO_GOARCH"
(
    cd "$RUNTIME_DIR"
    export GOARCH="$COCO_GOARCH"
    export GOARM=""
    export CGO_ENABLED=1
    export CC="$KATA_CC"
    make
)

for bin in kata-runtime containerd-shim-kata-v2 kata-monitor; do
    coco_install_exe "$RUNTIME_DIR/$bin" "$DEST_DIR/$bin"
done

coco_log "Kata artifacts are ready under $DEST_DIR"
