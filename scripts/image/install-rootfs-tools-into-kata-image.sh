#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

IMAGE="${IMAGE:-$COCO_SFTP_ROOT/images/kata-containers-cca.img}"
APT_SUITE="${APT_SUITE:-focal}"
APT_MIRROR="${APT_MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$COCO_ARTIFACTS_ROOT/rootfs-tools/debs}"
EXTRACT_DIR="${EXTRACT_DIR:-$COCO_ARTIFACTS_ROOT/rootfs-tools/extract}"
DRY_RUN=0
VERIFY_ONLY=0
SKIP_DOWNLOAD=0

ROOTFS_TOOL_PATHS=(
    /usr/bin/mkfs.erofs
    /usr/bin/mksquashfs
    /usr/lib/aarch64-linux-gnu/liblz4.so.1
    /usr/lib/aarch64-linux-gnu/libzstd.so.1
    /lib/aarch64-linux-gnu/liblzo2.so.2
)

ROOTFS_TOOL_PACKAGES=(
    erofs-utils:arm64
    squashfs-tools:arm64
    liblz4-1:arm64
    libzstd1:arm64
    liblzo2-2:arm64
)

usage() {
    cat <<EOF
Usage: $0 [--dry-run] [--verify-only] [--skip-download]

Install read-only rootfs image tools into the local Kata guest image.
This injects arm64 tools for Image CVM side rootfs image generation.

Inputs:
  IMAGE        Kata disk image. Default: $IMAGE
  APT_SUITE    Ubuntu suite for arm64 packages. Default: $APT_SUITE
  APT_MIRROR   Ubuntu ports mirror. Default: $APT_MIRROR
  DOWNLOAD_DIR Directory for downloaded arm64 .deb files. Default: $DOWNLOAD_DIR
  EXTRACT_DIR  Directory for extracted package payloads. Default: $EXTRACT_DIR

Installed in the guest image:
  /usr/bin/mkfs.erofs
  /usr/bin/mksquashfs
  /lib/aarch64-linux-gnu/lib{lz4,zstd,lzo2}.so.*
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
        --skip-download)
            SKIP_DOWNLOAD=1
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

verify_tools_in_ext4() {
    local part="$1"
    local missing=0 path

    for path in "${ROOTFS_TOOL_PATHS[@]}"; do
        if coco_file_exists_in_ext4 "$part" "$path"; then
            printf '[ok:image] %s\n' "$path"
        else
            printf '[missing:image] %s\n' "$path" >&2
            missing=1
        fi
    done

    [[ "$missing" -eq 0 ]]
}

verify_image_contents() {
    coco_require_cmd sfdisk dd debugfs mktemp grep
    local tmp part rc=0

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/coco-rootfs-tools-verify.XXXXXX")"
    trap 'rm -rf "$tmp"' RETURN
    part="$tmp/kata-rootfs.ext4"
    extract_rootfs_partition "$part"
    verify_tools_in_ext4 "$part" || rc=$?

    rm -rf "$tmp"
    trap - RETURN
    return "$rc"
}

download_packages() {
    coco_require_cmd apt-get
    coco_ensure_dir "$DOWNLOAD_DIR"

    local apt_root
    apt_root="$(mktemp -d "${TMPDIR:-/tmp}/coco-apt-arm64.XXXXXX")"
    trap 'rm -rf "$apt_root"' RETURN

    mkdir -p \
        "$apt_root/etc/apt/preferences.d" \
        "$apt_root/var/lib/apt/lists/partial" \
        "$apt_root/var/cache/apt/archives/partial"
    : > "$apt_root/status"
    cat > "$apt_root/etc/apt/sources.list" <<EOF
deb [arch=arm64 signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $APT_MIRROR $APT_SUITE main universe
deb [arch=arm64 signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $APT_MIRROR $APT_SUITE-updates main universe
deb [arch=arm64 signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $APT_MIRROR $APT_SUITE-security main universe
EOF

    (
        cd "$DOWNLOAD_DIR"
        apt-get \
            -o "Dir=$apt_root" \
            -o "Dir::Etc::sourcelist=$apt_root/etc/apt/sources.list" \
            -o "Dir::Etc::sourceparts=-" \
            -o "Dir::State::status=$apt_root/status" \
            -o "APT::Architecture=arm64" \
            -o "APT::Architectures=arm64" \
            update
        apt-get \
            -o "Dir=$apt_root" \
            -o "Dir::Etc::sourcelist=$apt_root/etc/apt/sources.list" \
            -o "Dir::Etc::sourceparts=-" \
            -o "Dir::State::status=$apt_root/status" \
            -o "APT::Architecture=arm64" \
            -o "APT::Architectures=arm64" \
            download "${ROOTFS_TOOL_PACKAGES[@]}"
    )

    rm -rf "$apt_root"
    trap - RETURN
}

extract_packages() {
    coco_require_cmd dpkg-deb find rm mkdir
    rm -rf "$EXTRACT_DIR"
    mkdir -p "$EXTRACT_DIR"

    local deb
    shopt -s nullglob
    for deb in "$DOWNLOAD_DIR"/*.deb; do
        dpkg-deb -x "$deb" "$EXTRACT_DIR"
    done
    shopt -u nullglob

    for path in "${ROOTFS_TOOL_PATHS[@]}"; do
        [[ -e "$EXTRACT_DIR$path" ]] || coco_die "extracted package payload is missing $path"
    done
}

debugfs_ensure_dir() {
    local part="$1"
    local path="$2"

    debugfs -w -R "mkdir $path" "$part" >/dev/null 2>&1 || true
    debugfs -w -R "set_inode_field $path mode 040755" "$part" >/dev/null
    debugfs -w -R "set_inode_field $path uid 0" "$part" >/dev/null
    debugfs -w -R "set_inode_field $path gid 0" "$part" >/dev/null
}

debugfs_install_file() {
    local part="$1"
    local src="$2"
    local dst="$3"
    local mode="$4"
    local resolved_src="$src"

    if [[ -L "$src" ]]; then
        resolved_src="$(readlink -f "$src")"
    fi

    debugfs -w -R "rm $dst" "$part" >/dev/null 2>&1 || true
    debugfs -w -R "write $resolved_src $dst" "$part" >/dev/null
    debugfs -w -R "set_inode_field $dst mode $mode" "$part" >/dev/null
    debugfs -w -R "set_inode_field $dst uid 0" "$part" >/dev/null
    debugfs -w -R "set_inode_field $dst gid 0" "$part" >/dev/null
    coco_log "installed guest image file $dst"
}

install_payload_into_ext4() {
    local part="$1"
    local path mode

    debugfs_ensure_dir "$part" /usr
    debugfs_ensure_dir "$part" /usr/bin
    debugfs_ensure_dir "$part" /usr/lib
    debugfs_ensure_dir "$part" /usr/lib/aarch64-linux-gnu
    debugfs_ensure_dir "$part" /lib
    debugfs_ensure_dir "$part" /lib/aarch64-linux-gnu

    for path in "${ROOTFS_TOOL_PATHS[@]}"; do
        case "$path" in
            /usr/bin/*)
                mode=0100755
                ;;
            *)
                mode=0100644
                ;;
        esac
        debugfs_install_file "$part" "$EXTRACT_DIR$path" "$path" "$mode"
    done
}

install_with_debugfs() {
    coco_require_cmd sfdisk dd debugfs mktemp stat
    [[ -f "$IMAGE" ]] || coco_die "missing Kata image: $IMAGE"
    [[ -w "$IMAGE" ]] || coco_die "Kata image is not writable: $IMAGE"

    local tmp part
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/coco-rootfs-tools-image-write.XXXXXX")"
    trap 'rm -rf "$tmp"' RETURN
    part="$tmp/kata-rootfs.ext4"

    extract_rootfs_partition "$part"
    install_payload_into_ext4 "$part"
    write_rootfs_partition "$part"
    sync

    rm -rf "$tmp"
    trap - RETURN
    coco_log "updated Kata image with read-only rootfs tools"
}

[[ -f "$IMAGE" ]] || coco_die "missing Kata image: $IMAGE"

if [[ "$VERIFY_ONLY" == "1" ]]; then
    if verify_image_contents; then
        coco_log "Kata guest image contains read-only rootfs tools"
    else
        coco_die "Kata image is missing read-only rootfs tools"
    fi
    exit 0
fi

if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] download arm64 packages into %q\n' "$DOWNLOAD_DIR"
    printf '[dry-run] extract packages into %q\n' "$EXTRACT_DIR"
    printf '[dry-run] inject mkfs.erofs, mksquashfs, and required libraries into %q\n' "$IMAGE"
    exit 0
fi

if [[ "$SKIP_DOWNLOAD" != "1" ]]; then
    download_packages
fi
extract_packages
install_with_debugfs

if verify_image_contents; then
    coco_log "Kata guest image contains read-only rootfs tools"
else
    coco_die "Kata image is missing read-only rootfs tools after install"
fi
