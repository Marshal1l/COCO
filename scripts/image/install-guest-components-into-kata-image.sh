#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

IMAGE="${IMAGE:-$COCO_SFTP_ROOT/images/kata-containers-cca.img}"
BIN_DIR="${BIN_DIR:-$COCO_GUEST_COMPONENTS_ARTIFACTS_DIR/bin}"
CONFIG_DIR="${CONFIG_DIR:-$COCO_GUEST_COMPONENTS_ARTIFACTS_DIR/config}"
MOUNT_DIR="${MOUNT_DIR:-$COCO_SFTP_ROOT/images/mnt-kata}"
INSTALL_METHOD="${INSTALL_METHOD:-debugfs}"
IMAGE_LOCK="${IMAGE_LOCK:-$COCO_ARTIFACTS_ROOT/locks/kata-containers-cca.img.lock}"
DRY_RUN=0
VERIFY_ONLY=0
INSTALL_IF_MISSING=0

usage() {
    cat <<EOF
Usage: $0 [--dry-run] [--verify-only] [--install-if-missing]

Install guest-side CoCo components into the local Kata guest image.
This script runs on the local build machine, not on the remote OpenCCA board.

Inputs:
  IMAGE      Kata disk image. Default: $IMAGE
  BIN_DIR    Built guest-component binaries. Default: $BIN_DIR
  CONFIG_DIR Guest-component configs. Default: $CONFIG_DIR
  MOUNT_DIR  Temporary local mount point. Default: $MOUNT_DIR
  INSTALL_METHOD  debugfs or mount. Default: $INSTALL_METHOD

Installed in the guest image:
  /usr/local/bin/{api-server-rest,attestation-agent,confidential-data-hub,ttrpc-cdh-tool,vsock-ttrpc-server}
  /root/guest-components/aa.toml
  /root/guest-components/cdh.toml
  /etc/attestation-agent.toml
  /etc/confidential-data-hub.toml
  /etc/image-rs-config.json
  /etc/resolv.conf

The default debugfs write path updates the image offline and does not require sudo.
Set INSTALL_METHOD=mount to use losetup/mount/cp/umount with local sudo.
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
        --install-if-missing)
            INSTALL_IF_MISSING=1
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

require_inputs() {
    local bin
    [[ -f "$IMAGE" ]] || coco_die "missing Kata image: $IMAGE"

    if [[ "$VERIFY_ONLY" == "1" ]]; then
        return 0
    fi

    for bin in "${COCO_GUEST_COMPONENT_BINS[@]}"; do
        [[ -f "$BIN_DIR/$bin" ]] || coco_die "missing guest-component binary: $BIN_DIR/$bin"
    done
    [[ -f "$CONFIG_DIR/attestation-agent.toml" ]] || coco_die "missing AA config: $CONFIG_DIR/attestation-agent.toml"
    [[ -f "$CONFIG_DIR/cdh.toml" ]] || coco_die "missing CDH config: $CONFIG_DIR/cdh.toml"
    [[ -f "$CONFIG_DIR/image-rs-config.json" ]] || coco_die "missing image-rs config: $CONFIG_DIR/image-rs-config.json"
}

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

verify_ext4_contents() {
    local part="$1"
    local missing=0 path bin

    for bin in "${COCO_GUEST_COMPONENT_BINS[@]}"; do
        path="/usr/local/bin/$bin"
        if coco_file_exists_in_ext4 "$part" "$path"; then
            printf '[ok:image] %s\n' "$path"
        else
            printf '[missing:image] %s\n' "$path" >&2
            missing=1
        fi
    done
    for path in \
        /root/guest-components/aa.toml \
        /root/guest-components/cdh.toml \
        /etc/attestation-agent.toml \
        /etc/confidential-data-hub.toml \
        /etc/image-rs-config.json; do
        if coco_file_exists_in_ext4 "$part" "$path"; then
            printf '[ok:image] %s\n' "$path"
        else
            printf '[missing:image] %s\n' "$path" >&2
            missing=1
        fi
    done
    if debugfs -R "cat /etc/resolv.conf" "$part" 2>/dev/null | grep -q '^nameserver 192\.168\.31\.1'; then
        printf '[ok:image] /etc/resolv.conf\n'
    else
        printf '[missing:image] /etc/resolv.conf nameserver 192.168.31.1\n' >&2
        missing=1
    fi

    [[ "$missing" -eq 0 ]]
}

verify_image_contents() {
    coco_require_cmd sfdisk dd debugfs mktemp grep
    local tmp part rc=0

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/coco-kata-image.XXXXXX")"
    trap 'rm -rf "$tmp"' RETURN
    part="$tmp/kata-rootfs.ext4"
    extract_rootfs_partition "$part"
    verify_ext4_contents "$part" || rc=$?

    rm -rf "$tmp"
    trap - RETURN
    return "$rc"
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

    debugfs -w -R "rm $dst" "$part" >/dev/null 2>&1 || true
    debugfs -w -R "write $src $dst" "$part" >/dev/null
    debugfs -w -R "set_inode_field $dst mode $mode" "$part" >/dev/null
    debugfs -w -R "set_inode_field $dst uid 0" "$part" >/dev/null
    debugfs -w -R "set_inode_field $dst gid 0" "$part" >/dev/null
    coco_log "installed guest image file $dst"
}

install_payload_into_ext4() {
    local part="$1"
    local bin
    local tmp_resolv

    debugfs_ensure_dir "$part" /usr
    debugfs_ensure_dir "$part" /usr/local
    debugfs_ensure_dir "$part" /usr/local/bin
    debugfs_ensure_dir "$part" /root
    debugfs_ensure_dir "$part" /root/guest-components
    debugfs_ensure_dir "$part" /etc

    for bin in "${COCO_GUEST_COMPONENT_BINS[@]}"; do
        debugfs_install_file "$part" "$BIN_DIR/$bin" "/usr/local/bin/$bin" 0100755
    done

    debugfs_install_file "$part" "$CONFIG_DIR/attestation-agent.toml" /root/guest-components/aa.toml 0100644
    debugfs_install_file "$part" "$CONFIG_DIR/cdh.toml" /root/guest-components/cdh.toml 0100644
    debugfs -w -R "rm /etc/attestation-agent.conf" "$part" >/dev/null 2>&1 || true
    debugfs -w -R "rm /etc/confidential-data-hub.conf" "$part" >/dev/null 2>&1 || true
    debugfs_install_file "$part" "$CONFIG_DIR/attestation-agent.toml" /etc/attestation-agent.toml 0100644
    debugfs_install_file "$part" "$CONFIG_DIR/cdh.toml" /etc/confidential-data-hub.toml 0100644
    debugfs_install_file "$part" "$CONFIG_DIR/image-rs-config.json" /etc/image-rs-config.json 0100644

    tmp_resolv="$(mktemp "${TMPDIR:-/tmp}/coco-guest-resolv.XXXXXX")"
cat > "$tmp_resolv" <<'EOF'
nameserver 192.168.31.1
options timeout:2 attempts:3
search .
EOF
    debugfs_install_file "$part" "$tmp_resolv" /etc/resolv.conf 0100644
    rm -f "$tmp_resolv"
}

install_with_debugfs() {
    coco_require_cmd sfdisk dd debugfs mktemp stat flock
    [[ -w "$IMAGE" ]] || coco_die "Kata image is not writable: $IMAGE"

    local tmp part
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/coco-kata-image-write.XXXXXX")"
    trap 'rm -rf "$tmp"' RETURN
    part="$tmp/kata-rootfs.ext4"

    extract_rootfs_partition "$part"
    install_payload_into_ext4 "$part"
    write_rootfs_partition "$part"
    sync

    rm -rf "$tmp"
    trap - RETURN
    coco_log "updated Kata image with guest-components using debugfs"
}

with_image_lock() {
    local lock_dir
    lock_dir="$(dirname "$IMAGE_LOCK")"
    coco_ensure_dir "$lock_dir"

    exec 9>"$IMAGE_LOCK"
    flock 9
    "$@"
}

install_with_mount() {
    coco_require_cmd sudo losetup mount umount install

    coco_ensure_dir "$MOUNT_DIR"
    loopdev=""
    mounted=0
    cleanup() {
        local rc=$?
        if [[ "$mounted" == "1" ]]; then
            sudo umount "$MOUNT_DIR" || true
        fi
        if [[ -n "$loopdev" ]]; then
            sudo losetup -d "$loopdev" || true
        fi
        exit "$rc"
    }
    trap cleanup EXIT

    loopdev="$(sudo losetup --find --partscan --show "$IMAGE")"
    partition="${loopdev}p1"
    if [[ ! -e "$partition" ]]; then
        sleep 1
    fi
    if [[ ! -e "$partition" ]]; then
        coco_die "loop partition $partition was not created for $IMAGE"
    fi

    sudo mount "$partition" "$MOUNT_DIR"
    mounted=1

    sudo install -d -m0755 "$MOUNT_DIR/usr/local/bin" "$MOUNT_DIR/root/guest-components"
    local_bin=""
    for local_bin in "${COCO_GUEST_COMPONENT_BINS[@]}"; do
        sudo install -m0755 "$BIN_DIR/$local_bin" "$MOUNT_DIR/usr/local/bin/$local_bin"
        coco_log "installed guest image binary /usr/local/bin/$local_bin"
    done

    sudo install -m0644 "$CONFIG_DIR/attestation-agent.toml" "$MOUNT_DIR/root/guest-components/aa.toml"
    sudo install -m0644 "$CONFIG_DIR/cdh.toml" "$MOUNT_DIR/root/guest-components/cdh.toml"
    sudo rm -f "$MOUNT_DIR/etc/attestation-agent.conf" "$MOUNT_DIR/etc/confidential-data-hub.conf"
    sudo install -m0644 "$CONFIG_DIR/attestation-agent.toml" "$MOUNT_DIR/etc/attestation-agent.toml"
    sudo install -m0644 "$CONFIG_DIR/cdh.toml" "$MOUNT_DIR/etc/confidential-data-hub.toml"
    sudo install -m0644 "$CONFIG_DIR/image-rs-config.json" "$MOUNT_DIR/etc/image-rs-config.json"
    sudo tee "$MOUNT_DIR/etc/resolv.conf" >/dev/null <<'EOF'
nameserver 192.168.31.1
options timeout:2 attempts:3
search .
EOF

    sync
    sudo umount "$MOUNT_DIR"
    mounted=0
    sudo losetup -d "$loopdev"
    loopdev=""
    trap - EXIT
}

require_inputs

if [[ "$VERIFY_ONLY" == "1" ]]; then
    if verify_image_contents; then
        coco_log "Kata guest image contains guest-components"
    else
        coco_die "Kata image is missing guest components"
    fi
    exit 0
fi

if [[ "$INSTALL_IF_MISSING" == "1" ]]; then
    if verify_image_contents; then
        coco_log "Kata guest image already contains guest-components"
        exit 0
    fi
    coco_log "Kata guest image is missing guest-components; installing locally"
fi

if [[ "$DRY_RUN" == "1" ]]; then
    if [[ "$INSTALL_METHOD" == "mount" ]]; then
        printf '[dry-run] sudo losetup --find --partscan --show %q\n' "$IMAGE"
        printf '[dry-run] sudo mount <loopdev>p1 %q\n' "$MOUNT_DIR"
        printf '[dry-run] install guest-component binaries into /usr/local/bin in the image\n'
        printf '[dry-run] install configs into /root/guest-components and /etc in the image\n'
        printf '[dry-run] sudo umount %q && sudo losetup -d <loopdev>\n' "$MOUNT_DIR"
    else
        printf '[dry-run] extract first partition from %q with dd\n' "$IMAGE"
        printf '[dry-run] write guest-component binaries and configs into the ext4 partition with debugfs\n'
        printf '[dry-run] write the updated partition back into %q with dd conv=notrunc\n' "$IMAGE"
    fi
    exit 0
fi

case "$INSTALL_METHOD" in
    debugfs)
        with_image_lock install_with_debugfs
        ;;
    mount)
        install_with_mount
        ;;
    *)
        coco_die "unknown INSTALL_METHOD: $INSTALL_METHOD"
        ;;
esac

if verify_image_contents; then
    coco_log "Kata guest image contains guest-components"
else
    coco_die "Kata image is missing guest components after install"
fi
