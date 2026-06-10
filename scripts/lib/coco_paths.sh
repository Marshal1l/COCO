#!/usr/bin/env bash

if [[ -n "${COCO_PATHS_SH_LOADED:-}" ]]; then
    return 0
fi
COCO_PATHS_SH_LOADED=1

COCO_ROOT_DIR="${COCO_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
COCO_SFTP_ROOT="${COCO_SFTP_ROOT:-$COCO_ROOT_DIR/COCO-SFTP}"
COCO_ARTIFACTS_ROOT="${COCO_ARTIFACTS_ROOT:-$COCO_ROOT_DIR/artifacts}"
COCO_GUEST_COMPONENTS_ARTIFACTS_DIR="${COCO_GUEST_COMPONENTS_ARTIFACTS_DIR:-$COCO_ARTIFACTS_ROOT/guest-components}"
COCO_GUEST_PULL_SNAPSHOTTER_ARTIFACTS_DIR="${COCO_GUEST_PULL_SNAPSHOTTER_ARTIFACTS_DIR:-$COCO_ARTIFACTS_ROOT/guest-pull-snapshotter}"
COCO_SFTP_REMOTE_ROOT="${COCO_SFTP_REMOTE_ROOT:-/root/COCO-SFTP}"
COCO_REMOTE_HOST="${COCO_REMOTE_HOST:-root@192.168.31.18}"
COCO_REMOTE_SSH_PORT="${COCO_REMOTE_SSH_PORT:-22}"
COCO_REMOTE_PASSWORD="${COCO_REMOTE_PASSWORD:-}"
COCO_RPI_HOST="${COCO_RPI_HOST:-mzh@192.168.31.52}"
COCO_RPI_SSH_PORT="${COCO_RPI_SSH_PORT:-22}"
COCO_RPI_PASSWORD="${COCO_RPI_PASSWORD:-}"

COCO_ARCH="${COCO_ARCH:-aarch64}"
COCO_GOARCH="${COCO_GOARCH:-arm64}"
COCO_LIBC="${COCO_LIBC:-musl}"
COCO_RUST_TARGET="${COCO_RUST_TARGET:-${COCO_ARCH}-unknown-linux-${COCO_LIBC}}"
COCO_GNU_CC="${COCO_GNU_CC:-aarch64-linux-gnu-gcc}"
COCO_MUSL_CC="${COCO_MUSL_CC:-aarch64-linux-musl-gcc}"
COCO_CROSS_COMPILE="${COCO_CROSS_COMPILE:-aarch64-linux-gnu-}"
COCO_GNU_STRIP="${COCO_GNU_STRIP:-${COCO_CROSS_COMPILE}strip}"
COCO_MUSL_STRIP="${COCO_MUSL_STRIP:-aarch64-linux-musl-strip}"

COCO_GUEST_COMPONENT_BINS=(
    api-server-rest
    attestation-agent
    confidential-data-hub
    ttrpc-cdh-tool
    vsock-ttrpc-server
)

COCO_GUEST_PULL_SNAPSHOTTER_BINS=(
    containerd-guest-pull-grpc
    guest-pull-overlayfs
)

COCO_RUNTIME_BUILD_COMPONENTS=(
    firecracker
    linux-image-share
    kata
    guest-pull-snapshotter
    guest-components
)

COCO_OPTIONAL_BUILD_COMPONENTS=(
    opencca
)

coco_log() {
    printf '[coco] %s\n' "$*"
}

coco_die() {
    printf '[coco] error: %s\n' "$*" >&2
    exit 1
}

coco_require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || coco_die "missing required command: $cmd"
    done
}

coco_ensure_dir() {
    mkdir -p "$@"
}

coco_install_exe() {
    local src="$1"
    local dst="$2"
    [[ -f "$src" ]] || coco_die "missing build artifact: $src"
    install -D -m0755 "$src" "$dst"
    coco_log "installed $dst"
}

coco_install_first_exe() {
    local dst="$1"
    shift

    local src
    for src in "$@"; do
        if [[ -f "$src" ]]; then
            coco_install_exe "$src" "$dst"
            return 0
        fi
    done

    coco_die "missing build artifact for $dst"
}

coco_install_data() {
    local src="$1"
    local dst="$2"
    [[ -f "$src" ]] || coco_die "missing build artifact: $src"
    install -D -m0644 "$src" "$dst"
    coco_log "installed $dst"
}

coco_strip_exe() {
    local file="$1"
    local strip_cmd="${COCO_STRIP:-}"
    local candidate

    [[ -f "$file" ]] || coco_die "missing executable to strip: $file"
    if [[ -z "$strip_cmd" ]]; then
        for candidate in "$COCO_MUSL_STRIP" "$COCO_GNU_STRIP" llvm-strip strip; do
            if command -v "$candidate" >/dev/null 2>&1; then
                strip_cmd="$candidate"
                break
            fi
        done
    fi

    if [[ -z "$strip_cmd" ]]; then
        coco_log "strip command unavailable; keeping $file unstripped"
        return 0
    fi

    "$strip_cmd" "$file" || coco_die "failed to strip $file with $strip_cmd"
    chmod 0755 "$file"
    coco_log "stripped $file"
}

coco_file_exists_in_ext4() {
    local image="$1"
    local path="$2"

    debugfs -R "stat $path" "$image" 2>&1 | grep -q '^Inode:'
}
