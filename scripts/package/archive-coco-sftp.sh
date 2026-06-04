#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

ARCHIVE_DIR="${ARCHIVE_DIR:-$COCO_ROOT_DIR/dist}"
ARCHIVE_NAME="${ARCHIVE_NAME:-COCO-SFTP-$(date +%Y%m%d-%H%M%S).tar.gz}"

coco_require_cmd tar
coco_ensure_dir "$ARCHIVE_DIR"

tar -C "$COCO_ROOT_DIR" \
    --exclude='COCO-SFTP/log' \
    --exclude='COCO-SFTP/images/mnt-rootfs' \
    --exclude='COCO-SFTP/images/mnt-kata' \
    --exclude='COCO-SFTP/images/lib' \
    --exclude='COCO-SFTP/.vscode' \
    -czf "$ARCHIVE_DIR/$ARCHIVE_NAME" COCO-SFTP

coco_log "created $ARCHIVE_DIR/$ARCHIVE_NAME"
