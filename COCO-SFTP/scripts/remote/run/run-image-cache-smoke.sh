#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../install" && pwd)/remote-install-common.sh"

require_root
require_cmd nerdctl
require_cmd systemctl

IMAGE="${COCO_IMAGE:-docker.io/library/busybox:latest}"
IMAGE_REF_ANNOTATION="${COCO_IMAGE_REF_ANNOTATION:-$IMAGE}"
IMAGE_CVM_NAME="${COCO_IMAGE_CVM_NAME:-coco-image-cvm}"
RUNTIME_CVM_NAME="${COCO_RUNTIME_CVM_NAME:-coco-runtime-cvm}"
IMAGE_CVM_BOOT_WAIT="${COCO_IMAGE_CVM_BOOT_WAIT:-10}"
KEEP_SMOKE="${COCO_KEEP_SMOKE:-0}"

cleanup() {
    if [[ "$KEEP_SMOKE" != "1" ]]; then
        nerdctl rm -f "$RUNTIME_CVM_NAME" "$IMAGE_CVM_NAME" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

systemctl is-active --quiet guest-pull-snapshotter
systemctl is-active --quiet containerd

nerdctl rm -f "$RUNTIME_CVM_NAME" "$IMAGE_CVM_NAME" >/dev/null 2>&1 || true

nerdctl run -d \
    --net=host \
    --name "$IMAGE_CVM_NAME" \
    --annotation "io.kubernetes.cri.image-name=$IMAGE_REF_ANNOTATION" \
    --annotation "io.kata-containers.is-image-cvm=true" \
    --snapshotter guest-pull \
    --runtime io.containerd.kata.v2 \
    "$IMAGE" sh -c "sleep 600"

sleep "$IMAGE_CVM_BOOT_WAIT"

nerdctl run --rm \
    --net=host \
    --name "$RUNTIME_CVM_NAME" \
    --annotation "io.kubernetes.cri.image-name=$IMAGE_REF_ANNOTATION" \
    --annotation "io.kata-containers.is-image-cvm=false" \
    --snapshotter guest-pull \
    --runtime io.containerd.kata.v2 \
    "$IMAGE" sh -c "echo coco-runtime-cvm-ok"

log_install "image-cache smoke run completed with $IMAGE"
