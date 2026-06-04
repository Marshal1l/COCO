#!/usr/bin/env bash

if [[ -n "${COCO_REMOTE_INSTALL_COMMON_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
COCO_REMOTE_INSTALL_COMMON_LOADED=1

COCO_INSTALL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COCO_ROOT="${COCO_ROOT:-$(cd "$COCO_INSTALL_SCRIPT_DIR/../../.." && pwd)}"

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        printf '[coco-remote] error: run this script as root on the remote host\n' >&2
        exit 1
    fi
}

log_install() {
    printf '[coco-remote] %s\n' "$*"
}

require_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        printf '[coco-remote] error: missing required file: %s\n' "$file" >&2
        exit 1
    fi
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf '[coco-remote] error: missing required command: %s\n' "$cmd" >&2
        exit 1
    fi
}

require_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        printf '[coco-remote] error: missing required directory: %s\n' "$dir" >&2
        exit 1
    fi
}
