#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

coco_require_cmd rsync ssh
if [[ -n "$COCO_REMOTE_PASSWORD" ]]; then
    coco_require_cmd sshpass
fi

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

ssh_transport=(
    ssh
    -p "$COCO_REMOTE_SSH_PORT"
    -oBatchMode=no
    -oStrictHostKeyChecking=accept-new
)
if [[ -n "$COCO_REMOTE_PASSWORD" ]]; then
    ssh_transport=(sshpass -p "$COCO_REMOTE_PASSWORD" "${ssh_transport[@]}")
fi
ssh_transport_string="$(printf ' %q' "${ssh_transport[@]}")"
ssh_transport_string="${ssh_transport_string# }"

coco_log "syncing $COCO_SFTP_ROOT/ to $COCO_REMOTE_HOST:$COCO_SFTP_REMOTE_ROOT/"
rsync -av --info=stats2,name1 \
    -e "$ssh_transport_string" \
    "${rsync_excludes[@]}" \
    "$COCO_SFTP_ROOT/" \
    "$COCO_REMOTE_HOST:$COCO_SFTP_REMOTE_ROOT/"
