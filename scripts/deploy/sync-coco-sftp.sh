#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

coco_require_cmd rsync ssh

rsync_excludes=(
    --exclude='.vscode/'
    --exclude='.git/'
    --exclude='log/'
    --exclude='images/mnt-rootfs/'
    --exclude='images/mnt-kata/'
    --exclude='images/lib/'
)

if [[ "${COCO_SYNC_BOARD_ASSETS:-0}" != "1" ]]; then
    rsync_excludes+=(
        --exclude='linux-host-kernel/'
        --exclude='opencca-assets/'
    )
fi

coco_log "syncing $COCO_SFTP_ROOT/ to $COCO_REMOTE_HOST:$COCO_SFTP_REMOTE_ROOT/"
rsync -av --info=stats2,name1 \
    -e "ssh -p $COCO_REMOTE_SSH_PORT -oBatchMode=no -oStrictHostKeyChecking=accept-new" \
    "${rsync_excludes[@]}" \
    "$COCO_SFTP_ROOT/" \
    "$COCO_REMOTE_HOST:$COCO_SFTP_REMOTE_ROOT/"
