#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../install" && pwd)/remote-install-common.sh"

missing=0

check_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        printf '[coco-remote-check] ok file: %s\n' "$file"
    else
        printf '[coco-remote-check] missing file: %s\n' "$file" >&2
        missing=1
    fi
}

check_dir() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        printf '[coco-remote-check] ok dir: %s\n' "$dir"
    else
        printf '[coco-remote-check] missing dir: %s\n' "$dir" >&2
        missing=1
    fi
}

check_cmd() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        printf '[coco-remote-check] ok command: %s\n' "$cmd"
    else
        printf '[coco-remote-check] missing command: %s\n' "$cmd" >&2
        missing=1
    fi
}

check_systemd_unit() {
    local unit="$1"
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit"; then
        printf '[coco-remote-check] ok systemd unit: %s\n' "$unit"
    else
        printf '[coco-remote-check] missing systemd unit: %s\n' "$unit" >&2
        missing=1
    fi
}

check_dir "$COCO_ROOT"
check_dir "$COCO_ROOT/scripts/remote/install"
check_dir "$COCO_ROOT/configs/containerd"
check_dir "$COCO_ROOT/configs/kata-containers"
check_dir "$COCO_ROOT/configs/cni"

check_file "$COCO_ROOT/configs/containerd/config.toml"
check_file "$COCO_ROOT/configs/kata-containers/configuration-fc.toml"
check_file "$COCO_ROOT/configs/cni/10-coco-bridge.conf"
check_file "$COCO_ROOT/guest-pull/containerd-guest-pull-grpc"
check_file "$COCO_ROOT/guest-pull/guest-pull-overlayfs"
check_file "$COCO_ROOT/kata-bins/containerd-shim-kata-v2"
check_file "$COCO_ROOT/kata-bins/kata-runtime"
check_file "$COCO_ROOT/nerdctl-bin/nerdctl"
check_file "$COCO_ROOT/images/kata-containers-cca.img"

check_cmd systemctl
check_cmd containerd

if command -v systemctl >/dev/null 2>&1; then
    check_systemd_unit containerd.service
fi

if [[ "$missing" -ne 0 ]]; then
    printf '[coco-remote-check] remote host is not ready for COCO-SFTP install\n' >&2
    exit 1
fi

printf '[coco-remote-check] remote host and COCO-SFTP payload are ready for install\n'
