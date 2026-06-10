#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

COMPONENT=""
DO_SYNC=1
DRY_RUN=0
REMOTE_REINSTALL=0
REMOTE_RESTART=0

usage() {
    cat <<EOF
Usage: $0 --component NAME [options]

Build one changed component, refresh COCO-SFTP, optionally sync it to the
remote host, and optionally run the matching remote install steps.

Components:
  firecracker              Build Firecracker CCA VMM into COCO-SFTP/firecracker-bins/firecracker.
  linux-image-share        Build reusable guest kernel into COCO-SFTP/firecracker-bins/Image.
  kata                     Build Kata runtime/shim/monitor into COCO-SFTP/kata-bins/.
  guest-pull-snapshotter   Build guest-pull snapshotter into COCO-SFTP/guest-pull/.
  guest-components         Build guest-side components and inject them into the local Kata image.

Options:
  --no-sync                Build and check locally without connecting to the remote host.
  --remote-reinstall       After sync, run the matching remote install script.
  --remote-restart         After remote install, restart guest-pull-snapshotter and containerd.
  --dry-run                Print commands without running them.
  -h, --help               Show this help.

Environment:
  COCO_REMOTE_HOST         Remote SSH target. Default: $COCO_REMOTE_HOST
  COCO_REMOTE_SSH_PORT     Remote SSH port. Default: $COCO_REMOTE_SSH_PORT
  COCO_REMOTE_PASSWORD     Optional SSH password. If set, sshpass is used.
  COCO_SFTP_REMOTE_ROOT    Remote runtime root. Default: $COCO_SFTP_REMOTE_ROOT
EOF
}

run_cmd() {
    printf '[update]'
    printf ' %q' "$@"
    printf '\n'
    if [[ "$DRY_RUN" == "0" ]]; then
        "$@"
    fi
}

run_remote() {
    local command="$1"
    local ssh_cmd=(
        ssh
        -p "$COCO_REMOTE_SSH_PORT"
        -oBatchMode=no
        -oStrictHostKeyChecking=accept-new
    )
    if [[ -n "$COCO_REMOTE_PASSWORD" ]]; then
        coco_require_cmd sshpass
        ssh_cmd=(sshpass -p "$COCO_REMOTE_PASSWORD" "${ssh_cmd[@]}")
    fi
    run_cmd "${ssh_cmd[@]}" "$COCO_REMOTE_HOST" "$command"
}

build_component() {
    case "$1" in
        firecracker)
            run_cmd "$COCO_ROOT_DIR/scripts/build/build-firecracker.sh"
            ;;
        linux-image-share)
            run_cmd "$COCO_ROOT_DIR/scripts/build/build-linux-image-share.sh"
            ;;
        kata)
            run_cmd "$COCO_ROOT_DIR/scripts/build/build-kata-containers.sh"
            ;;
        guest-pull-snapshotter)
            run_cmd "$COCO_ROOT_DIR/scripts/build/build-guest-pull-snapshotter.sh"
            ;;
        guest-components)
            run_cmd "$COCO_ROOT_DIR/scripts/build/build-guest-components.sh"
            run_cmd "$COCO_ROOT_DIR/scripts/image/install-guest-components-into-kata-image.sh"
            ;;
        *)
            coco_die "unknown component: $1"
            ;;
    esac
}

remote_install_command() {
    case "$1" in
        firecracker|linux-image-share|guest-components)
            printf '%s' "cd '$COCO_SFTP_REMOTE_ROOT' && ./scripts/remote/install/install-configs.sh"
            ;;
        kata)
            printf '%s' "cd '$COCO_SFTP_REMOTE_ROOT' && ./scripts/remote/install/install-kata.sh && ./scripts/remote/install/install-configs.sh"
            ;;
        guest-pull-snapshotter)
            printf '%s' "cd '$COCO_SFTP_REMOTE_ROOT' && ./scripts/remote/install/install-guest-pull-snapshotter.sh && ./scripts/remote/install/install-configs.sh"
            ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --component)
            [[ $# -ge 2 ]] || coco_die "--component requires a name"
            COMPONENT="$2"
            shift
            ;;
        --no-sync)
            DO_SYNC=0
            ;;
        --remote-reinstall)
            REMOTE_REINSTALL=1
            ;;
        --remote-restart)
            REMOTE_RESTART=1
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

[[ -n "$COMPONENT" ]] || {
    usage >&2
    coco_die "--component is required"
}

build_component "$COMPONENT"
run_cmd "$COCO_ROOT_DIR/scripts/package/prepare-coco-sftp.sh"
run_cmd "$COCO_ROOT_DIR/scripts/package/check-coco-sftp.sh"
run_cmd "$COCO_ROOT_DIR/scripts/package/check-remote-install-flow.sh"

if [[ "$DO_SYNC" == "1" ]]; then
    run_cmd "$COCO_ROOT_DIR/scripts/deploy/sync-coco-sftp.sh"
else
    printf '[update] sync skipped by --no-sync\n'
fi

if [[ "$REMOTE_REINSTALL" == "1" ]]; then
    [[ "$DO_SYNC" == "1" ]] || coco_die "--remote-reinstall requires sync"
    run_remote "$(remote_install_command "$COMPONENT")"
fi

if [[ "$REMOTE_RESTART" == "1" ]]; then
    [[ "$DO_SYNC" == "1" ]] || coco_die "--remote-restart requires sync"
    run_remote "cd '$COCO_SFTP_REMOTE_ROOT' && ./scripts/remote/run/start-container-runtime.sh"
fi
