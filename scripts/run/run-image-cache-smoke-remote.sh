#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

IMAGE="${COCO_IMAGE:-docker.m.daocloud.io/library/busybox:latest}"
IMAGE_REF_ANNOTATION="${COCO_IMAGE_REF_ANNOTATION:-$IMAGE}"
ANNOTATION_SET=0
NERDCTL_NET="${COCO_NERDCTL_NET:-coco-bridge}"
NERDCTL_DNS="${COCO_NERDCTL_DNS:-192.168.31.1}"
CGROUP_MANAGER="${COCO_NERDCTL_CGROUP_MANAGER:-cgroupfs}"
IMAGE_CVM_BOOT_WAIT="${COCO_IMAGE_CVM_BOOT_WAIT:-15}"
SMOKE_TIMEOUT="${COCO_IMAGE_CACHE_SMOKE_TIMEOUT:-240}"
KEEP_SMOKE="${COCO_KEEP_SMOKE:-0}"
SERIAL_LOG="${COCO_IMAGE_CACHE_SERIAL_LOG:-0}"
SERIAL_TAG="${COCO_IMAGE_CACHE_SERIAL_TAG:-imagecache-smoke}"
DISABLE_IMAGE_CVM_PREFETCH="${COCO_DISABLE_IMAGE_CVM_PREFETCH:-0}"
DO_PREPARE=0
CHECK_ONLY=1
DRY_RUN=0

if [[ "${COCO_IMAGE_CACHE_PREPARE:-0}" == "1" ]]; then
    DO_PREPARE=1
    CHECK_ONLY=0
fi
if [[ -n "${COCO_IMAGE_REF_ANNOTATION:-}" ]]; then
    ANNOTATION_SET=1
fi

usage() {
    cat <<EOF
Usage: $0 [options]

Run the verified RK3588 ImageCache smoke test through SSH.

Verified default on 2026-06-10:
  image: $IMAGE
  net:   coco-bridge
  dns:   192.168.31.1
  wait:  15 seconds

Options:
  --image IMAGE          Container image for both Image CVM and Runtime CVM.
  --annotation IMAGE     io.kubernetes.cri.image-name annotation. Default: image.
  --net NAME             nerdctl network. Default: $NERDCTL_NET.
  --dns SERVER           nerdctl DNS server. Default: $NERDCTL_DNS.
  --wait SECONDS         Wait after Image CVM starts. Default: $IMAGE_CVM_BOOT_WAIT.
  --timeout SECONDS      Overall remote smoke timeout. Default: $SMOKE_TIMEOUT.
  --keep-smoke           Leave the Image CVM running after the test.
  --prepare              Run full remote network/service preparation first.
  --no-check             Skip the lightweight remote readiness check.
  --no-prefetch          Disable Runtime CVM startup prefetch; it still uses Image CVM sharing on guest_pull.
  --serial-log           Capture RK3588 serial log through the Raspberry Pi.
  --serial-tag TAG       Serial log tag. Default: $SERIAL_TAG.
  --dry-run              Print the SSH command without running it.
  -h, --help             Show this help.

Environment:
  COCO_REMOTE_HOST       Default: $COCO_REMOTE_HOST
  COCO_REMOTE_PASSWORD   Optional SSH password, e.g. root
  COCO_RPI_HOST          Default: $COCO_RPI_HOST
  COCO_RPI_PASSWORD      Optional SSH password, e.g. root
  COCO_SFTP_REMOTE_ROOT  Default: $COCO_SFTP_REMOTE_ROOT
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            [[ $# -ge 2 ]] || coco_die "--image requires a value"
            IMAGE="$2"
            if [[ "$ANNOTATION_SET" == "0" ]]; then
                IMAGE_REF_ANNOTATION="$IMAGE"
            fi
            shift
            ;;
        --annotation)
            [[ $# -ge 2 ]] || coco_die "--annotation requires a value"
            IMAGE_REF_ANNOTATION="$2"
            ANNOTATION_SET=1
            shift
            ;;
        --net)
            [[ $# -ge 2 ]] || coco_die "--net requires a value"
            NERDCTL_NET="$2"
            shift
            ;;
        --dns)
            [[ $# -ge 2 ]] || coco_die "--dns requires a value"
            NERDCTL_DNS="$2"
            shift
            ;;
        --wait)
            [[ $# -ge 2 ]] || coco_die "--wait requires a value"
            IMAGE_CVM_BOOT_WAIT="$2"
            shift
            ;;
        --timeout)
            [[ $# -ge 2 ]] || coco_die "--timeout requires a value"
            SMOKE_TIMEOUT="$2"
            shift
            ;;
        --keep-smoke)
            KEEP_SMOKE=1
            ;;
        --prepare)
            DO_PREPARE=1
            CHECK_ONLY=0
            ;;
        --no-check)
            CHECK_ONLY=0
            ;;
        --no-prefetch)
            DISABLE_IMAGE_CVM_PREFETCH=true
            ;;
        --serial-log)
            SERIAL_LOG=1
            ;;
        --serial-tag)
            [[ $# -ge 2 ]] || coco_die "--serial-tag requires a value"
            SERIAL_TAG="$2"
            shift
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

coco_require_cmd ssh
if [[ -n "$COCO_REMOTE_PASSWORD" ]]; then
    coco_require_cmd sshpass
fi

ssh_cmd=(
    ssh
    -tt
    -p "$COCO_REMOTE_SSH_PORT"
    -oBatchMode=no
    -oStrictHostKeyChecking=accept-new
    -oUserKnownHostsFile=/tmp/coco_known_hosts
)
if [[ -n "$COCO_REMOTE_PASSWORD" ]]; then
    ssh_cmd=(sshpass -p "$COCO_REMOTE_PASSWORD" "${ssh_cmd[@]}")
fi

env_args=(
    "COCO_IMAGE=$IMAGE"
    "COCO_IMAGE_REF_ANNOTATION=$IMAGE_REF_ANNOTATION"
    "COCO_NERDCTL_NET=$NERDCTL_NET"
    "COCO_NERDCTL_DNS=$NERDCTL_DNS"
    "COCO_NERDCTL_CGROUP_MANAGER=$CGROUP_MANAGER"
    "COCO_IMAGE_CVM_BOOT_WAIT=$IMAGE_CVM_BOOT_WAIT"
    "COCO_KEEP_SMOKE=$KEEP_SMOKE"
    "COCO_DISABLE_IMAGE_CVM_PREFETCH=$DISABLE_IMAGE_CVM_PREFETCH"
)

remote_root_q="$(printf '%q' "$COCO_SFTP_REMOTE_ROOT")"
remote_cmd="set -euo pipefail; cd $remote_root_q; "
if [[ "$DO_PREPARE" == "1" ]]; then
    remote_cmd+="./scripts/remote/run/start-container-runtime.sh; "
    env_args+=("COCO_IMAGE_CACHE_CHECK_NETWORK=0")
elif [[ "$CHECK_ONLY" == "1" ]]; then
    remote_cmd+="./scripts/remote/run/check-image-cache-network.sh; "
    env_args+=("COCO_IMAGE_CACHE_CHECK_NETWORK=0")
fi

env_prefix=""
for kv in "${env_args[@]}"; do
    env_prefix+="$(printf '%q' "$kv") "
done

remote_cmd+="nerdctl rm -f coco-runtime-cvm coco-image-cvm >/dev/null 2>&1 || true; "
remote_cmd+="${env_prefix}timeout $(printf '%q' "$SMOKE_TIMEOUT") ./scripts/remote/run/run-image-cache-smoke.sh"

coco_log "remote ImageCache smoke: host=$COCO_REMOTE_HOST image=$IMAGE net=$NERDCTL_NET dns=$NERDCTL_DNS wait=${IMAGE_CVM_BOOT_WAIT}s"
printf '[coco]'
printf ' %q' "${ssh_cmd[@]}" "$COCO_REMOTE_HOST" "$remote_cmd"
printf '\n'

if [[ "$DRY_RUN" == "0" ]]; then
    if [[ "$SERIAL_LOG" == "1" ]]; then
        "$COCO_ROOT_DIR/scripts/debug/rk3588-serial-log.sh" start --tag "$SERIAL_TAG"
    fi

    smoke_status=0
    "${ssh_cmd[@]}" "$COCO_REMOTE_HOST" "$remote_cmd" || smoke_status=$?

    if [[ "$SERIAL_LOG" == "1" ]]; then
        "$COCO_ROOT_DIR/scripts/debug/rk3588-serial-log.sh" fetch || true
    fi

    exit "$smoke_status"
fi
