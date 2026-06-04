#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

LINUX_DIR="${LINUX_DIR:-$COCO_ROOT_DIR/linux-image-share}"
LINUX_OUT_DIR="${LINUX_OUT_DIR:-$LINUX_DIR/out/coco-arm64}"
DEST_IMAGE="${DEST_IMAGE:-$COCO_SFTP_ROOT/firecracker-bins/Image}"
FRAGMENT_CONFIG="${FRAGMENT_CONFIG:-$LINUX_DIR/rk3588_fragment.config}"
JOBS="${JOBS:-$(nproc)}"

coco_require_cmd make install "${COCO_CROSS_COMPILE}gcc"
coco_ensure_dir "$LINUX_OUT_DIR" "$(dirname "$DEST_IMAGE")"

coco_log "building reusable guest kernel from linux-image-share"
if [[ ! -f "$LINUX_OUT_DIR/.config" ]]; then
    make -C "$LINUX_DIR" O="$LINUX_OUT_DIR" ARCH=arm64 CROSS_COMPILE="$COCO_CROSS_COMPILE" defconfig
    if [[ -f "$FRAGMENT_CONFIG" ]]; then
        "$LINUX_DIR/scripts/kconfig/merge_config.sh" -m -O "$LINUX_OUT_DIR" "$LINUX_OUT_DIR/.config" "$FRAGMENT_CONFIG"
    fi
fi

make -C "$LINUX_DIR" O="$LINUX_OUT_DIR" ARCH=arm64 CROSS_COMPILE="$COCO_CROSS_COMPILE" olddefconfig
make -C "$LINUX_DIR" O="$LINUX_OUT_DIR" ARCH=arm64 CROSS_COMPILE="$COCO_CROSS_COMPILE" -j"$JOBS" Image

coco_install_data "$LINUX_OUT_DIR/arch/arm64/boot/Image" "$DEST_IMAGE"
coco_log "guest kernel Image is ready at $DEST_IMAGE"
