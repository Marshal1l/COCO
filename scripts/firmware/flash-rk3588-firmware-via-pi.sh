#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

OPENCCA_DIR="${OPENCCA_DIR:-$COCO_ROOT_DIR/opencca}"
OPENCCA_SNAPSHOT_DIR="${OPENCCA_SNAPSHOT_DIR:-$OPENCCA_DIR/snapshot}"
COCO_RPI_FLASH_ROOT="${COCO_RPI_FLASH_ROOT:-/home/mzh/opencca-flash}"
COCO_RPI_SUDO_PASSWORD="${COCO_RPI_SUDO_PASSWORD:-$COCO_RPI_PASSWORD}"
DO_SYNC=1
FLASH_COMMAND=""
WAIT_RK=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $0 [options]

Sync verified OpenCCA firmware artifacts to the Raspberry Pi flash host and
optionally ask the Pi to flash/reboot the RK3588.

Options:
  --sync-only       Only sync snapshot artifacts to the Pi. This is the default.
  --flash-mmc       Sync, then run: sudo ./flash.sh mmc
  --flash-spi       Sync, then run: sudo ./flash.sh spi
  --reboot          Sync, then run: sudo ./flash.sh reboot
  --no-sync         Skip rsync and only run the selected flash command.
  --wait-rk         Wait for RK3588 SSH after the flash command.
  --dry-run         Print commands without running them.
  -h, --help        Show this help.

Environment:
  COCO_RPI_HOST          Default: $COCO_RPI_HOST
  COCO_RPI_PASSWORD      Optional SSH password for the Pi, e.g. root
  COCO_RPI_SUDO_PASSWORD Defaults to COCO_RPI_PASSWORD
  COCO_RPI_FLASH_ROOT    Default: $COCO_RPI_FLASH_ROOT
  COCO_REMOTE_HOST       RK3588 SSH target for --wait-rk. Default: $COCO_REMOTE_HOST
  COCO_REMOTE_PASSWORD   Optional RK3588 SSH password, e.g. root
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sync-only)
            FLASH_COMMAND=""
            ;;
        --flash-mmc)
            FLASH_COMMAND="mmc"
            ;;
        --flash-spi)
            FLASH_COMMAND="spi"
            ;;
        --reboot)
            FLASH_COMMAND="reboot"
            ;;
        --no-sync)
            DO_SYNC=0
            ;;
        --wait-rk)
            WAIT_RK=1
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

coco_require_cmd ssh rsync sha256sum
if [[ -n "$COCO_RPI_PASSWORD$COCO_REMOTE_PASSWORD" ]]; then
    coco_require_cmd sshpass
fi

run_cmd() {
    printf '[coco-firmware]'
    printf ' %q' "$@"
    printf '\n'
    if [[ "$DRY_RUN" == "0" ]]; then
        "$@"
    fi
}

require_artifact() {
    local name="$1"
    [[ -f "$OPENCCA_SNAPSHOT_DIR/$name" ]] || coco_die "missing firmware artifact: $OPENCCA_SNAPSHOT_DIR/$name"
}

pi_ssh_cmd=(
    ssh
    -tt
    -p "$COCO_RPI_SSH_PORT"
    -oBatchMode=no
    -oStrictHostKeyChecking=accept-new
    -oUserKnownHostsFile=/tmp/coco_known_hosts
)
pi_ssh_for_rsync=(
    ssh
    -p "$COCO_RPI_SSH_PORT"
    -oBatchMode=no
    -oStrictHostKeyChecking=accept-new
    -oUserKnownHostsFile=/tmp/coco_known_hosts
)
if [[ -n "$COCO_RPI_PASSWORD" ]]; then
    pi_ssh_cmd=(sshpass -p "$COCO_RPI_PASSWORD" "${pi_ssh_cmd[@]}")
    pi_ssh_for_rsync=(sshpass -p "$COCO_RPI_PASSWORD" "${pi_ssh_for_rsync[@]}")
fi

if [[ "$DO_SYNC" == "1" ]]; then
    for name in idbloader.img u-boot.itb u-boot-rockchip-spi.bin tf-rmm.elf; do
        require_artifact "$name"
    done

    rsync_ssh="$(printf ' %q' "${pi_ssh_for_rsync[@]}")"
    rsync_ssh="${rsync_ssh# }"
    run_cmd rsync -av --checksum -e "$rsync_ssh" \
        "$OPENCCA_SNAPSHOT_DIR/idbloader.img" \
        "$OPENCCA_SNAPSHOT_DIR/u-boot.itb" \
        "$OPENCCA_SNAPSHOT_DIR/u-boot-rockchip-spi.bin" \
        "$OPENCCA_SNAPSHOT_DIR/tf-rmm.elf" \
        "$COCO_RPI_HOST:$COCO_RPI_FLASH_ROOT/snapshot/"
fi

if [[ -n "$FLASH_COMMAND" ]]; then
    [[ -n "$COCO_RPI_SUDO_PASSWORD" ]] || coco_die "set COCO_RPI_SUDO_PASSWORD or COCO_RPI_PASSWORD for sudo on the Pi"
    remote_root_q="$(printf '%q' "$COCO_RPI_FLASH_ROOT")"
    sudo_pass_q="$(printf '%q' "$COCO_RPI_SUDO_PASSWORD")"
    flash_cmd_q="$(printf '%q' "$FLASH_COMMAND")"
    remote_cmd="set -euo pipefail; cd $remote_root_q; printf '%s\n' $sudo_pass_q | sudo -S ./flash.sh $flash_cmd_q"
    run_cmd "${pi_ssh_cmd[@]}" "$COCO_RPI_HOST" "$remote_cmd"
fi

if [[ "$WAIT_RK" == "1" ]]; then
    rk_ssh_cmd=(
        ssh
        -p "$COCO_REMOTE_SSH_PORT"
        -oBatchMode=no
        -oStrictHostKeyChecking=accept-new
        -oUserKnownHostsFile=/tmp/coco_known_hosts
        -oConnectTimeout=8
    )
    if [[ -n "$COCO_REMOTE_PASSWORD" ]]; then
        rk_ssh_cmd=(sshpass -p "$COCO_REMOTE_PASSWORD" "${rk_ssh_cmd[@]}")
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        run_cmd "${rk_ssh_cmd[@]}" "$COCO_REMOTE_HOST" "uname -a"
    else
        coco_log "waiting for RK3588 SSH: $COCO_REMOTE_HOST"
        for _ in $(seq 1 60); do
            if "${rk_ssh_cmd[@]}" "$COCO_REMOTE_HOST" "uname -a" >/dev/null 2>&1; then
                "${rk_ssh_cmd[@]}" "$COCO_REMOTE_HOST" "hostname; uname -a"
                exit 0
            fi
            sleep 3
        done
        coco_die "RK3588 did not come back over SSH"
    fi
fi
