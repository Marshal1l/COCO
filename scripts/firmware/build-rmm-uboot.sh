#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

OPENCCA_DIR="${OPENCCA_DIR:-$COCO_ROOT_DIR/opencca}"
OPENCCA_BUILDCONF_DIR="${OPENCCA_BUILDCONF_DIR:-$OPENCCA_DIR/opencca-build/buildconf}"
OPENCCA_SNAPSHOT_DIR="${OPENCCA_SNAPSHOT_DIR:-$OPENCCA_DIR/snapshot}"
BUILD_RMM=1
BUILD_UBOOT=1
DRY_RUN=0

OPENCCA_LOG="${OPENCCA_LOG:-50}"
OPENCCA_DEBUG="${OPENCCA_DEBUG:-1}"
OPENCCA_ENABLE_PERF="${OPENCCA_ENABLE_PERF:-1}"
OPENCCA_CLEAN_BUILD="${OPENCCA_CLEAN_BUILD:-0}"
OPENCCA_NPROC="${OPENCCA_NPROC:-$(nproc)}"

usage() {
    cat <<EOF
Usage: $0 [options]

Build RMM and repack U-Boot with the verified RK3588/OpenCCA path.
Default action is: build RMM, copy tf-rmm.elf to snapshot, then rebuild u-boot.itb.

Options:
  --rmm-only          Build only tf-rmm.elf.
  --uboot-only        Repack only U-Boot using the current snapshot/tf-rmm.elf.
  --clean             Pass CLEAN_BUILD=1 to the OpenCCA makefile.
  --dry-run           Print commands without running them.
  -h, --help          Show this help.

Environment:
  OPENCCA_LOG         Default: $OPENCCA_LOG
  OPENCCA_DEBUG       Default: $OPENCCA_DEBUG
  OPENCCA_ENABLE_PERF Default: $OPENCCA_ENABLE_PERF
  OPENCCA_NPROC       Default: $OPENCCA_NPROC
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rmm-only)
            BUILD_RMM=1
            BUILD_UBOOT=0
            ;;
        --uboot-only)
            BUILD_RMM=0
            BUILD_UBOOT=1
            ;;
        --clean)
            OPENCCA_CLEAN_BUILD=1
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

run_cmd() {
    printf '[coco-firmware]'
    printf ' %q' "$@"
    printf '\n'
    if [[ "$DRY_RUN" == "0" ]]; then
        "$@"
    fi
}

make_opencca() {
    local target="$1"
    run_cmd make \
        -C "$OPENCCA_BUILDCONF_DIR" \
        -f firmware_opencca.mk \
        "LOG=$OPENCCA_LOG" \
        "DEBUG=$OPENCCA_DEBUG" \
        "ENABLE_OPENCCA_PERF=$OPENCCA_ENABLE_PERF" \
        "CLEAN_BUILD=$OPENCCA_CLEAN_BUILD" \
        "NPROC=$OPENCCA_NPROC" \
        "$target"
}

verify_file() {
    local file="$1"
    [[ -f "$file" ]] || coco_die "missing expected firmware artifact: $file"
    sha256sum "$file"
}

[[ -d "$OPENCCA_BUILDCONF_DIR" ]] || coco_die "missing OpenCCA buildconf dir: $OPENCCA_BUILDCONF_DIR"

if [[ "$BUILD_RMM" == "1" ]]; then
    make_opencca rmm
fi

if [[ "$BUILD_UBOOT" == "1" ]]; then
    [[ -f "$OPENCCA_SNAPSHOT_DIR/tf-rmm.elf" ]] || coco_die "missing $OPENCCA_SNAPSHOT_DIR/tf-rmm.elf; build RMM first"
    make_opencca uboot
fi

if [[ "$DRY_RUN" == "0" ]]; then
    coco_log "firmware snapshot artifacts:"
    verify_file "$OPENCCA_SNAPSHOT_DIR/tf-rmm.elf"
    verify_file "$OPENCCA_SNAPSHOT_DIR/idbloader.img"
    verify_file "$OPENCCA_SNAPSHOT_DIR/u-boot.itb"
    verify_file "$OPENCCA_SNAPSHOT_DIR/u-boot-rockchip-spi.bin"
fi
