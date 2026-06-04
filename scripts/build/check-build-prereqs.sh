#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

missing=0
seen_cmds=" "
requested_components=("$@")

if [[ "${#requested_components[@]}" -eq 0 ]]; then
    requested_components=("${COCO_RUNTIME_BUILD_COMPONENTS[@]}")
fi

check_cmd() {
    local cmd="$1"
    if [[ "$seen_cmds" == *" $cmd "* ]]; then
        return 0
    fi
    seen_cmds="$seen_cmds$cmd "
    if command -v "$cmd" >/dev/null 2>&1; then
        printf '[ok:cmd] %s\n' "$cmd"
    else
        printf '[missing:cmd] %s\n' "$cmd" >&2
        missing=1
    fi
}

check_dir() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        printf '[ok:dir] %s\n' "$dir"
    else
        printf '[missing:dir] %s\n' "$dir" >&2
        missing=1
    fi
}

check_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        printf '[ok:file] %s\n' "$file"
    else
        printf '[missing:file] %s\n' "$file" >&2
        missing=1
    fi
}

check_cmd make

check_component() {
    case "$1" in
        firecracker)
            check_cmd cargo
            check_cmd rustup
            check_cmd "$COCO_MUSL_CC"
            check_dir "$COCO_ROOT_DIR/Firecracker-CCA"
            check_dir "$COCO_ROOT_DIR/firecracker-deps"
            check_dir "$COCO_ROOT_DIR/firecracker-deps/kvm-bindings"
            check_dir "$COCO_ROOT_DIR/firecracker-deps/kvm-ioctls"
            check_dir "$COCO_ROOT_DIR/firecracker-deps/linux-loader"
            check_dir "$COCO_ROOT_DIR/firecracker-deps/vm-memory"
            ;;
        linux-image-share)
            check_cmd "${COCO_CROSS_COMPILE}gcc"
            check_dir "$COCO_ROOT_DIR/linux-image-share"
            check_file "$COCO_ROOT_DIR/linux-image-share/scripts/kconfig/merge_config.sh"
            ;;
        kata)
            check_cmd go
            check_cmd "$COCO_GNU_CC"
            check_dir "$COCO_ROOT_DIR/kata-containers-cca/src/runtime"
            ;;
        guest-components)
            check_cmd cargo
            check_cmd rustup
            check_cmd "$COCO_MUSL_CC"
            check_dir "$COCO_ROOT_DIR/guest-components"
            ;;
        guest-pull-snapshotter)
            check_cmd go
            check_dir "$COCO_ROOT_DIR/guest-pull-snapshotter"
            check_file "$COCO_ROOT_DIR/guest-pull-snapshotter/Makefile"
            ;;
        opencca)
            check_dir "$COCO_ROOT_DIR/opencca"
            check_file "$COCO_ROOT_DIR/opencca/opencca-build/scripts/build_all.sh"
            ;;
        *)
            printf '[unknown:component] %s\n' "$1" >&2
            missing=1
            ;;
    esac
}

for component in "${requested_components[@]}"; do
    check_component "$component"
done

if [[ "$missing" -ne 0 ]]; then
    coco_die "build prerequisites are incomplete"
fi

coco_log "build prerequisites are present"
