#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

MANIFEST="${MANIFEST:-$COCO_SFTP_ROOT/MANIFEST.generated.txt}"
TMP_MANIFEST="$(mktemp "${TMPDIR:-/tmp}/coco-sftp-manifest.XXXXXX")"
trap 'rm -f "$TMP_MANIFEST"' EXIT

coco_ensure_dir \
    "$COCO_SFTP_ROOT/cni/bin" \
    "$COCO_SFTP_ROOT/configs/cni" \
    "$COCO_SFTP_ROOT/configs/containerd" \
    "$COCO_SFTP_ROOT/configs/kata-containers" \
    "$COCO_SFTP_ROOT/firecracker-bins" \
    "$COCO_SFTP_ROOT/guest-pull" \
    "$COCO_SFTP_ROOT/images" \
    "$COCO_SFTP_ROOT/kata-bins" \
    "$COCO_SFTP_ROOT/linux-host-kernel" \
    "$COCO_SFTP_ROOT/nerdctl-bin" \
    "$COCO_SFTP_ROOT/opencca-assets" \
    "$COCO_SFTP_ROOT/qemu-bins" \
    "$COCO_SFTP_ROOT/log"

{
    printf '# COCO-SFTP Generated Manifest\n'
    printf '# local_root=%s\n' "$COCO_SFTP_ROOT"
    printf '# remote_root=%s\n' "$COCO_SFTP_REMOTE_ROOT"
    printf '# generated_at=%s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    find "$COCO_SFTP_ROOT" \
        -path "$COCO_SFTP_ROOT/images/mnt-rootfs" -prune -o \
        -path "$COCO_SFTP_ROOT/images/mnt-kata" -prune -o \
        -path "$COCO_SFTP_ROOT/log" -prune -o \
        -path "$COCO_SFTP_ROOT/linux-host-kernel" -prune -o \
        -path "$COCO_SFTP_ROOT/opencca-assets" -prune -o \
        -name "$(basename "$MANIFEST")" -prune -o \
        -type f -printf '%P\t%s bytes\n' | sort
} > "$TMP_MANIFEST"

mv "$TMP_MANIFEST" "$MANIFEST"
trap - EXIT

coco_log "wrote $MANIFEST"
