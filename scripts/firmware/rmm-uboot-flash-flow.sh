#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

DO_BUILD=1
FLASH_MODE="sync-only"
WAIT_RK=0
RUN_IMAGECACHE=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $0 [options]

Convenience flow for the fixed RK3588 firmware loop:
  1. build RMM and repack U-Boot,
  2. sync artifacts to the Raspberry Pi flash host,
  3. optionally flash/reboot the RK3588,
  4. optionally run the verified ImageCache smoke test.

Options:
  --no-build          Skip RMM/U-Boot build.
  --sync-only         Sync firmware to Pi only. Default.
  --flash-mmc         Flash idbloader.img + u-boot.itb to RK3588 MMC.
  --flash-spi         Flash u-boot-rockchip-spi.bin to RK3588 SPI.
  --reboot            Reboot RK3588 through the Pi.
  --wait-rk           Wait for RK3588 SSH after flash/reboot.
  --test-imagecache   Run scripts/run/run-image-cache-smoke-remote.sh after RK is up.
  --dry-run           Print commands without running them.
  -h, --help          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build)
            DO_BUILD=0
            ;;
        --sync-only)
            FLASH_MODE="sync-only"
            ;;
        --flash-mmc)
            FLASH_MODE="flash-mmc"
            ;;
        --flash-spi)
            FLASH_MODE="flash-spi"
            ;;
        --reboot)
            FLASH_MODE="reboot"
            ;;
        --wait-rk)
            WAIT_RK=1
            ;;
        --test-imagecache)
            RUN_IMAGECACHE=1
            ;;
        --dry-run)
            DRY_RUN=1
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

run_step() {
    printf '[coco-flow]'
    printf ' %q' "$@"
    printf '\n'
    if [[ "$DRY_RUN" == "0" ]]; then
        "$@"
    fi
}

dry_run_arg=()
if [[ "$DRY_RUN" == "1" ]]; then
    dry_run_arg=(--dry-run)
fi

if [[ "$DO_BUILD" == "1" ]]; then
    run_step "$COCO_ROOT_DIR/scripts/firmware/build-rmm-uboot.sh" "${dry_run_arg[@]}"
fi

flash_args=(--"$FLASH_MODE")
if [[ "$WAIT_RK" == "1" || ( "$RUN_IMAGECACHE" == "1" && "$FLASH_MODE" != "sync-only" ) ]]; then
    flash_args+=(--wait-rk)
fi
run_step "$COCO_ROOT_DIR/scripts/firmware/flash-rk3588-firmware-via-pi.sh" "${dry_run_arg[@]}" "${flash_args[@]}"

if [[ "$RUN_IMAGECACHE" == "1" ]]; then
    imagecache_args=("${dry_run_arg[@]}")
    if [[ "${COCO_IMAGE_CACHE_PREPARE:-0}" == "1" ]]; then
        imagecache_args+=(--prepare)
    fi
    run_step "$COCO_ROOT_DIR/scripts/run/run-image-cache-smoke-remote.sh" "${imagecache_args[@]}"
fi
