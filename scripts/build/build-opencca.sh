#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

OPENCCA_DIR="${OPENCCA_DIR:-$COCO_ROOT_DIR/opencca}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-$OPENCCA_DIR/snapshot}"
DEST_DIR="${DEST_DIR:-$COCO_SFTP_ROOT/opencca-assets}"
MODE="${1:-collect}"

usage() {
    cat <<EOF
Usage: $0 [collect|build|docker-shell]

collect       Copy already-built OpenCCA firmware/kernel artifacts into COCO-SFTP.
build         Run opencca/opencca-build/scripts/build_all.sh, then collect artifacts.
docker-shell  Enter the OpenCCA build container through opencca-build/docker.

This script does not flash the board. Flashing remains under opencca/opencca-flash/.
EOF
}

collect_artifacts() {
    coco_ensure_dir "$DEST_DIR"
    local name
    for name in idbloader.img u-boot.itb Image tf-rmm.elf bl31.elf lkvm rk3588-kernel-config; do
        if [[ -f "$SNAPSHOT_DIR/$name" ]]; then
            coco_install_data "$SNAPSHOT_DIR/$name" "$DEST_DIR/$name"
        fi
    done
    if [[ -f "$OPENCCA_DIR/rootfs/opencca-image-rockchip-rock5b-rk3588.img" ]]; then
        coco_log "rootfs image is available at $OPENCCA_DIR/rootfs/opencca-image-rockchip-rock5b-rk3588.img"
        coco_log "large system images are not copied into COCO-SFTP automatically"
    fi
}

case "$MODE" in
    collect)
        collect_artifacts
        ;;
    build)
        coco_require_cmd bash
        (cd "$OPENCCA_DIR/opencca-build/scripts" && ./build_all.sh ${OPENCCA_BUILD_ARGS:-})
        collect_artifacts
        ;;
    docker-shell)
        coco_require_cmd make
        (cd "$OPENCCA_DIR/opencca-build/docker" && make start && make enter)
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        coco_die "unknown mode: $MODE"
        ;;
esac
