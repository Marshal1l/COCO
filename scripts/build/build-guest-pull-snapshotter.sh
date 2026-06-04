#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

SNAPSHOTTER_DIR="${SNAPSHOTTER_DIR:-$COCO_ROOT_DIR/guest-pull-snapshotter}"
DEST_DIR="${DEST_DIR:-$COCO_SFTP_ROOT/guest-pull}"
ARTIFACT_DEST_DIR="${ARTIFACT_DEST_DIR:-$COCO_GUEST_PULL_SNAPSHOTTER_ARTIFACTS_DIR/bin}"
SNAPSHOTTER_GOARCH="${SNAPSHOTTER_GOARCH:-$COCO_GOARCH}"

coco_require_cmd make go install
coco_ensure_dir "$DEST_DIR" "$ARTIFACT_DEST_DIR"

coco_log "building guest-pull-snapshotter for linux/$SNAPSHOTTER_GOARCH"
(
    cd "$SNAPSHOTTER_DIR"
    GOOS=linux GOARCH="$SNAPSHOTTER_GOARCH" make build
)

for bin in "${COCO_GUEST_PULL_SNAPSHOTTER_BINS[@]}"; do
    coco_install_exe "$SNAPSHOTTER_DIR/bin/$bin" "$ARTIFACT_DEST_DIR/$bin"
    coco_install_exe "$SNAPSHOTTER_DIR/bin/$bin" "$DEST_DIR/$bin"
done

coco_log "guest-pull-snapshotter artifacts are ready under $DEST_DIR"
