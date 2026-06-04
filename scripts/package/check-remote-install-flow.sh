#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

missing=0

check_file() {
    local rel="$1"
    if [[ -f "$COCO_SFTP_ROOT/$rel" ]]; then
        printf '[ok:remote-flow] %s\n' "$rel"
    else
        printf '[missing:remote-flow] %s\n' "$rel" >&2
        missing=1
    fi
}

check_grep() {
    local pattern="$1"
    local rel="$2"
    if grep -Eq "$pattern" "$COCO_SFTP_ROOT/$rel"; then
        printf '[ok:remote-flow] %s matches %s\n' "$rel" "$pattern"
    else
        printf '[missing:remote-flow] %s does not match %s\n' "$rel" "$pattern" >&2
        missing=1
    fi
}

check_no_grep() {
    local pattern="$1"
    local rel="$2"
    if grep -Eq "$pattern" "$COCO_SFTP_ROOT/$rel"; then
        printf '[bad:remote-flow] %s unexpectedly matches %s\n' "$rel" "$pattern" >&2
        missing=1
    else
        printf '[ok:remote-flow] %s does not match %s\n' "$rel" "$pattern"
    fi
}

check_file "scripts/remote/install/all.sh"
check_file "scripts/remote/install/install-cni.sh"
check_file "scripts/remote/install/install-configs.sh"
check_file "scripts/remote/install/install-guest-pull-snapshotter.sh"
check_file "scripts/remote/install/install-kata.sh"
check_file "scripts/remote/install/install-nerdctl.sh"
check_file "scripts/remote/check/preflight.sh"
check_file "scripts/remote/run/start-container-runtime.sh"
check_file "scripts/remote/run/run-image-cache-smoke.sh"
check_file "cni/SOURCE.md"
check_file "cni/bin/bridge"
check_file "cni/bin/firewall"
check_file "cni/bin/host-local"
check_file "cni/bin/loopback"
check_file "cni/bin/portmap"
check_file "configs/cni/10-coco-bridge.conf"
check_file "configs/containerd/config.toml"
check_file "configs/kata-containers/configuration-fc.toml"
check_file "guest-pull/containerd-guest-pull-grpc"
check_file "guest-pull/guest-pull-overlayfs"
check_file "kata-bins/kata-runtime"
check_file "kata-bins/kata-monitor"
check_file "kata-bins/containerd-shim-kata-v2"
check_file "nerdctl-bin/nerdctl"
check_file "nerdctl-bin/containerd-rootless.sh"
check_file "nerdctl-bin/containerd-rootless-setuptool.sh"
check_file "firecracker-bins/firecracker"
check_file "firecracker-bins/Image"
check_file "images/kata-containers-cca.img"

check_grep 'snapshotter[[:space:]]*=[[:space:]]*"guest-pull"' "configs/containerd/config.toml"
check_grep '\[proxy_plugins\.guest-pull\]' "configs/containerd/config.toml"
check_grep '/run/containerd-guest-pull-grpc/containerd-guest-pull-grpc\.sock' "configs/containerd/config.toml"
check_grep 'ConfigPath[[:space:]]*=[[:space:]]*"/opt/kata/share/defaults/kata-containers/configuration\.toml"' "configs/containerd/config.toml"
check_grep 'container_annotations.*io.kubernetes.cri.image-name' "configs/containerd/config.toml"
check_grep 'container_annotations.*io.kata-containers' "configs/containerd/config.toml"
check_grep 'pod_annotations.*io.kata-containers' "configs/containerd/config.toml"
check_grep 'path[[:space:]]*=[[:space:]]*"/root/COCO-SFTP/firecracker-bins/firecracker"' "configs/kata-containers/configuration-fc.toml"
check_grep 'kernel[[:space:]]*=[[:space:]]*"/root/COCO-SFTP/firecracker-bins/Image"' "configs/kata-containers/configuration-fc.toml"
check_grep 'image[[:space:]]*=[[:space:]]*"/root/COCO-SFTP/images/kata-containers-cca\.img"' "configs/kata-containers/configuration-fc.toml"
check_grep 'confidential_guest[[:space:]]*=[[:space:]]*true' "configs/kata-containers/configuration-fc.toml"
check_no_grep 'install-host-kernel\.sh' "scripts/remote/install/all.sh"
check_grep 'Before=containerd\.service' "scripts/remote/install/install-guest-pull-snapshotter.sh"
check_grep 'restart guest-pull-snapshotter' "scripts/remote/run/start-container-runtime.sh"
check_grep 'restart containerd' "scripts/remote/run/start-container-runtime.sh"
check_grep 'io\.kata-containers\.is-image-cvm=true' "scripts/remote/run/run-image-cache-smoke.sh"
check_grep 'io\.kata-containers\.is-image-cvm=false' "scripts/remote/run/run-image-cache-smoke.sh"

if [[ "$missing" -ne 0 ]]; then
    coco_die "remote install flow is incomplete"
fi

coco_log "remote install flow is structurally ready without firmware or host-kernel install"
