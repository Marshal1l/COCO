#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../install" && pwd)/remote-install-common.sh"

require_root
require_cmd nerdctl
require_cmd systemctl

# Verified on RK3588/OpenCCA on 2026-06-10:
#   net=coco-bridge, dns=192.168.31.1, image=docker.m.daocloud.io/library/busybox:latest.
IMAGE="${COCO_IMAGE:-docker.m.daocloud.io/library/busybox:latest}"
IMAGE_REF_ANNOTATION="${COCO_IMAGE_REF_ANNOTATION:-$IMAGE}"
IMAGE_CVM_NAME="${COCO_IMAGE_CVM_NAME:-coco-image-cvm}"
RUNTIME_CVM_NAME="${COCO_RUNTIME_CVM_NAME:-coco-runtime-cvm}"
IMAGE_CVM_BOOT_WAIT="${COCO_IMAGE_CVM_BOOT_WAIT:-15}"
CGROUP_MANAGER="${COCO_NERDCTL_CGROUP_MANAGER:-cgroupfs}"
NERDCTL_DNS="${COCO_NERDCTL_DNS:-192.168.31.1}"
NERDCTL_NET="${COCO_NERDCTL_NET:-coco-bridge}"
NERDCTL_ADD_HOSTS="${COCO_NERDCTL_ADD_HOSTS:-}"
KEEP_SMOKE="${COCO_KEEP_SMOKE:-0}"
CHECK_NETWORK="${COCO_IMAGE_CACHE_CHECK_NETWORK:-1}"

DNS_ARGS=()
if [[ -n "$NERDCTL_DNS" ]]; then
    DNS_ARGS+=(--dns "$NERDCTL_DNS")
fi

NET_ARGS=()
if [[ -n "$NERDCTL_NET" ]]; then
    NET_ARGS+=(--net "$NERDCTL_NET")
fi

ADD_HOST_ARGS=()
if [[ -n "$NERDCTL_ADD_HOSTS" ]]; then
    IFS=',' read -r -a add_hosts <<< "$NERDCTL_ADD_HOSTS"
    for add_host in "${add_hosts[@]}"; do
        [[ -n "$add_host" ]] || continue
        ADD_HOST_ARGS+=(--add-host "$add_host")
    done
fi

cleanup() {
    if [[ "$KEEP_SMOKE" != "1" ]]; then
        nerdctl rm -f "$RUNTIME_CVM_NAME" "$IMAGE_CVM_NAME" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

systemctl is-active --quiet guest-pull-snapshotter
systemctl is-active --quiet containerd

if [[ "$NERDCTL_NET" == "coco-bridge" ]]; then
    require_file /etc/cni/net.d/10-coco-bridge.conflist
    require_cmd iptables
    if ! iptables -t nat -C POSTROUTING -s 10.88.0.0/16 ! -o coco0 -j MASQUERADE 2>/dev/null; then
        log_install "warning: coco-bridge NAT rule is missing; run ./scripts/remote/run/start-container-runtime.sh first"
    fi
fi

if [[ "$CHECK_NETWORK" == "1" && "$NERDCTL_NET" == "coco-bridge" ]]; then
    "$COCO_ROOT/scripts/remote/run/check-image-cache-network.sh"
fi

log_install "using image-cache smoke network: net=$NERDCTL_NET dns=${NERDCTL_DNS:-none} image=$IMAGE wait=${IMAGE_CVM_BOOT_WAIT}s"

nerdctl rm -f "$RUNTIME_CVM_NAME" "$IMAGE_CVM_NAME" >/dev/null 2>&1 || true

nerdctl run -d \
    --cgroup-manager="$CGROUP_MANAGER" \
    "${NET_ARGS[@]}" \
    "${DNS_ARGS[@]}" \
    "${ADD_HOST_ARGS[@]}" \
    --name "$IMAGE_CVM_NAME" \
    --annotation "io.kubernetes.cri.image-name=$IMAGE_REF_ANNOTATION" \
    --annotation "io.kata-containers.is-image-cvm=true" \
    --snapshotter guest-pull \
    --runtime io.containerd.kata.v2 \
    "$IMAGE" sh -c "sleep 600"

sleep "$IMAGE_CVM_BOOT_WAIT"

nerdctl run --rm \
    --cgroup-manager="$CGROUP_MANAGER" \
    "${NET_ARGS[@]}" \
    "${DNS_ARGS[@]}" \
    "${ADD_HOST_ARGS[@]}" \
    --name "$RUNTIME_CVM_NAME" \
    --annotation "io.kubernetes.cri.image-name=$IMAGE_REF_ANNOTATION" \
    --annotation "io.kata-containers.is-image-cvm=false" \
    --snapshotter guest-pull \
    --runtime io.containerd.kata.v2 \
    "$IMAGE" sh -c "echo coco-runtime-cvm-ok"

log_install "image-cache smoke run completed with $IMAGE"
