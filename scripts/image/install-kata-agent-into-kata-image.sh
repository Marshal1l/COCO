#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

IMAGE="${IMAGE:-$COCO_SFTP_ROOT/images/kata-containers-cca.img}"
AGENT_BIN="${AGENT_BIN:-$COCO_ARTIFACTS_ROOT/kata-agent/bin/kata-agent}"
DRY_RUN=0
VERIFY_ONLY=0

usage() {
    cat <<EOF
Usage: $0 [--dry-run] [--verify-only]

Install a rebuilt kata-agent into the local Kata guest image.

Inputs:
  IMAGE      Kata disk image. Default: $IMAGE
  AGENT_BIN Rebuilt kata-agent. Default: $AGENT_BIN

Installed in the guest image:
  /usr/bin/kata-agent
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        --verify-only)
            VERIFY_ONLY=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            coco_die "unknown option: $1"
            ;;
    esac
    shift
done

extract_partition_field() {
    local field="$1"
    sfdisk -d "$IMAGE" | sed -n "s/^[^:]*:.*$field=[[:space:]]*\\([0-9]\\+\\),.*/\\1/p" | head -n 1
}

extract_rootfs_partition() {
    local part="$1"
    local start size
    start="$(extract_partition_field start)"
    size="$(extract_partition_field size)"
    [[ -n "$start" && -n "$size" ]] || coco_die "cannot locate first partition in $IMAGE"

    dd if="$IMAGE" of="$part" bs=512 skip="$start" count="$size" status=none
}

write_rootfs_partition() {
    local part="$1"
    local start size expected_size actual_size
    start="$(extract_partition_field start)"
    size="$(extract_partition_field size)"
    [[ -n "$start" && -n "$size" ]] || coco_die "cannot locate first partition in $IMAGE"

    expected_size="$((size * 512))"
    actual_size="$(stat -c '%s' "$part")"
    [[ "$actual_size" -eq "$expected_size" ]] || \
        coco_die "partition copy size changed: expected $expected_size bytes, got $actual_size bytes"

    dd if="$part" of="$IMAGE" bs=512 seek="$start" conv=notrunc status=none
}

debugfs_install_agent() {
    local part="$1"

    debugfs -w -R "mkdir /usr" "$part" >/dev/null 2>&1 || true
    debugfs -w -R "mkdir /usr/bin" "$part" >/dev/null 2>&1 || true
    debugfs -w -R "set_inode_field /usr/bin mode 040755" "$part" >/dev/null
    debugfs -w -R "set_inode_field /usr/bin uid 0" "$part" >/dev/null
    debugfs -w -R "set_inode_field /usr/bin gid 0" "$part" >/dev/null

    debugfs -w -R "rm /usr/bin/kata-agent" "$part" >/dev/null 2>&1 || true
    debugfs -w -R "write $AGENT_BIN /usr/bin/kata-agent" "$part" >/dev/null
    debugfs -w -R "set_inode_field /usr/bin/kata-agent mode 0100755" "$part" >/dev/null
    debugfs -w -R "set_inode_field /usr/bin/kata-agent uid 0" "$part" >/dev/null
    debugfs -w -R "set_inode_field /usr/bin/kata-agent gid 0" "$part" >/dev/null
}

verify_image_contents() {
    coco_require_cmd sfdisk dd debugfs mktemp grep
    local tmp part rc=0

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/coco-kata-agent-image.XXXXXX")"
    trap 'rm -rf "$tmp"' RETURN
    part="$tmp/kata-rootfs.ext4"
    extract_rootfs_partition "$part"
    if coco_file_exists_in_ext4 "$part" /usr/bin/kata-agent; then
        printf '[ok:image] /usr/bin/kata-agent\n'
    else
        printf '[missing:image] /usr/bin/kata-agent\n' >&2
        rc=1
    fi

    rm -rf "$tmp"
    trap - RETURN
    return "$rc"
}

install_with_debugfs() {
    coco_require_cmd sfdisk dd debugfs mktemp stat
    [[ -f "$IMAGE" ]] || coco_die "missing Kata image: $IMAGE"
    [[ -f "$AGENT_BIN" ]] || coco_die "missing kata-agent binary: $AGENT_BIN"
    [[ -w "$IMAGE" ]] || coco_die "Kata image is not writable: $IMAGE"

    local tmp part
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/coco-kata-agent-image-write.XXXXXX")"
    trap 'rm -rf "$tmp"' RETURN
    part="$tmp/kata-rootfs.ext4"

    extract_rootfs_partition "$part"
    debugfs_install_agent "$part"
    write_rootfs_partition "$part"
    sync

    rm -rf "$tmp"
    trap - RETURN
    coco_log "updated Kata image with rebuilt kata-agent"
}

[[ -f "$IMAGE" ]] || coco_die "missing Kata image: $IMAGE"

if [[ "$VERIFY_ONLY" == "1" ]]; then
    if verify_image_contents; then
        coco_log "Kata guest image contains kata-agent"
    else
        coco_die "Kata image is missing kata-agent"
    fi
    exit 0
fi

if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] extract first partition from %q with dd\n' "$IMAGE"
    printf '[dry-run] write %q into /usr/bin/kata-agent with debugfs\n' "$AGENT_BIN"
    printf '[dry-run] write the updated partition back into %q with dd conv=notrunc\n' "$IMAGE"
    exit 0
fi

install_with_debugfs
verify_image_contents
