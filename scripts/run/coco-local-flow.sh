#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

DO_BUILD=0
DO_ARCHIVE=0
DO_SYNC=0
DRY_RUN=0
CHECK_PREREQS=0
COMPONENTS=()
SKIP_COMPONENTS=()

usage() {
    cat <<EOF
Usage: $0 [options]

Prepare and verify the local COCO-SFTP runtime tree.

Default behavior:
  - create/refresh the COCO-SFTP manifest
  - check required fixed and built runtime files
  - do not rebuild large components
  - do not connect to the remote host

Options:
  --build                 Build all source-built components before checking.
  --check-prereqs         Check local build tools and source directories.
  --component NAME        Build one component. Repeatable.
                          Names: firecracker, linux-image-share, kata,
                          guest-pull-snapshotter, guest-components, opencca
                          Default --build excludes opencca host kernel/firmware.
  --skip NAME             Skip one component during --build. Repeatable.
  --archive               Create a local COCO-SFTP tarball after checks.
  --sync                  Sync to the remote host after checks. Explicit only.
  --dry-run               Print the workflow without running commands.
  -h, --help              Show this help.

Environment:
  COCO_SFTP_ROOT          Local runtime tree. Default: \$COCO_ROOT_DIR/COCO-SFTP
  COCO_SFTP_REMOTE_ROOT   Remote runtime tree. Default: /root/COCO-SFTP
  COCO_REMOTE_HOST        Remote SSH target. Default: root@192.168.137.10
EOF
}

run_step() {
    local label="$1"
    shift
    printf '[flow] %s\n' "$label"
    printf '       %q' "$@"
    printf '\n'
    if [[ "$DRY_RUN" == "0" ]]; then
        "$@"
    fi
}

build_component() {
    case "$1" in
        firecracker)
            run_step "build Firecracker CCA VMM" "$COCO_ROOT_DIR/scripts/build/build-firecracker.sh"
            ;;
        linux-image-share)
            run_step "build reusable guest kernel" "$COCO_ROOT_DIR/scripts/build/build-linux-image-share.sh"
            ;;
        kata)
            run_step "build Kata runtime/shim/monitor" "$COCO_ROOT_DIR/scripts/build/build-kata-containers.sh"
            ;;
        guest-components)
            run_step "build guest components" "$COCO_ROOT_DIR/scripts/build/build-guest-components.sh"
            run_step "install guest components into local Kata image if needed" \
                "$COCO_ROOT_DIR/scripts/image/install-guest-components-into-kata-image.sh" --install-if-missing
            ;;
        guest-pull-snapshotter)
            run_step "build guest-pull snapshotter" "$COCO_ROOT_DIR/scripts/build/build-guest-pull-snapshotter.sh"
            ;;
        opencca)
            run_step "collect OpenCCA firmware/kernel artifacts" "$COCO_ROOT_DIR/scripts/build/build-opencca.sh" collect
            ;;
        *)
            coco_die "unknown component: $1"
            ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build)
            DO_BUILD=1
            ;;
        --check-prereqs)
            CHECK_PREREQS=1
            ;;
        --component)
            [[ $# -ge 2 ]] || coco_die "--component requires a name"
            COMPONENTS+=("$2")
            shift
            ;;
        --skip)
            [[ $# -ge 2 ]] || coco_die "--skip requires a name"
            SKIP_COMPONENTS+=("$2")
            shift
            ;;
        --archive)
            DO_ARCHIVE=1
            ;;
        --sync)
            DO_SYNC=1
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

if [[ "$DO_BUILD" == "1" ]]; then
    COMPONENTS=("${COCO_RUNTIME_BUILD_COMPONENTS[@]}")
fi

BUILD_COMPONENTS=()
if [[ "${#COMPONENTS[@]}" -gt 0 ]]; then
    for component in "${COMPONENTS[@]}"; do
        skip=0
        for skipped in "${SKIP_COMPONENTS[@]}"; do
            if [[ "$component" == "$skipped" ]]; then
                skip=1
                break
            fi
        done
        if [[ "$skip" == "0" ]]; then
            BUILD_COMPONENTS+=("$component")
        fi
    done
fi

run_step "prepare COCO-SFTP directory skeleton and manifest" "$COCO_ROOT_DIR/scripts/package/prepare-coco-sftp.sh"

if [[ "$CHECK_PREREQS" == "1" || "${#BUILD_COMPONENTS[@]}" -gt 0 ]]; then
    if [[ "${#BUILD_COMPONENTS[@]}" -gt 0 ]]; then
        run_step "check local build prerequisites" "$COCO_ROOT_DIR/scripts/build/check-build-prereqs.sh" "${BUILD_COMPONENTS[@]}"
    else
        run_step "check local build prerequisites" "$COCO_ROOT_DIR/scripts/build/check-build-prereqs.sh"
    fi
fi

if [[ "${#COMPONENTS[@]}" -gt 0 ]]; then
    for component in "${COMPONENTS[@]}"; do
        skip=0
        for skipped in "${SKIP_COMPONENTS[@]}"; do
            if [[ "$component" == "$skipped" ]]; then
                skip=1
                break
            fi
        done
        if [[ "$skip" == "1" ]]; then
            printf '[flow] skip component %s\n' "$component"
            continue
        fi
        build_component "$component"
    done
    run_step "refresh manifest after build outputs" "$COCO_ROOT_DIR/scripts/package/prepare-coco-sftp.sh"
fi

run_step "check required COCO-SFTP runtime files" "$COCO_ROOT_DIR/scripts/package/check-coco-sftp.sh"
run_step "check remote install flow structure" "$COCO_ROOT_DIR/scripts/package/check-remote-install-flow.sh"

if [[ "$DO_ARCHIVE" == "1" ]]; then
    run_step "archive COCO-SFTP" "$COCO_ROOT_DIR/scripts/package/archive-coco-sftp.sh"
fi

if [[ "$DO_SYNC" == "1" ]]; then
    run_step "sync COCO-SFTP to remote host" "$COCO_ROOT_DIR/scripts/deploy/sync-coco-sftp.sh"
else
    printf '[flow] remote sync skipped; pass --sync when %s is reachable\n' "$COCO_REMOTE_HOST"
fi
