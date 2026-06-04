#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

source_built_files=(
    "configs/cni/10-coco-bridge.conf"
    "configs/containerd/config.toml"
    "configs/kata-containers/configuration-fc.toml"
    "firecracker-bins/firecracker"
    "firecracker-bins/Image"
    "kata-bins/containerd-shim-kata-v2"
    "kata-bins/kata-monitor"
    "kata-bins/kata-runtime"
)

required_cni_files=(
    "cni/bin/bridge"
    "cni/bin/firewall"
    "cni/bin/host-local"
    "cni/bin/loopback"
    "cni/bin/portmap"
)

fixed_files=(
    "cni/SOURCE.md"
    "${required_cni_files[@]}"
    "guest-pull/containerd-guest-pull-grpc"
    "guest-pull/guest-pull-overlayfs"
    "images/kata-containers-cca.img"
    "images/rootfs.ext4"
    "nerdctl-bin/nerdctl"
    "nerdctl-bin/containerd-rootless.sh"
    "nerdctl-bin/containerd-rootless-setuptool.sh"
    "qemu-bins/qemu-special"
)

missing=0

check_group() {
    local group="$1"
    shift
    local rel
    for rel in "$@"; do
        if [[ ! -e "$COCO_SFTP_ROOT/$rel" ]]; then
            printf '[missing:%s] %s\n' "$group" "$rel" >&2
            missing=1
        fi
    done
}

check_group source-built "${source_built_files[@]}"
check_group fixed-artifact "${fixed_files[@]}"

if command -v file >/dev/null 2>&1; then
    for rel in "${required_cni_files[@]}"; do
        if [[ -f "$COCO_SFTP_ROOT/$rel" ]] && ! file "$COCO_SFTP_ROOT/$rel" | grep -q 'ARM aarch64'; then
            printf '[bad:cni-arch] %s is not an AArch64 plugin\n' "$rel" >&2
            missing=1
        fi
    done
else
    printf '[warn:cni-arch] file(1) is unavailable; skipped CNI architecture check\n' >&2
fi

for bin in "${COCO_GUEST_COMPONENT_BINS[@]}"; do
    if [[ ! -f "$COCO_GUEST_COMPONENTS_ARTIFACTS_DIR/bin/$bin" ]]; then
        printf '[missing:guest-component-artifact] %s\n' "$COCO_GUEST_COMPONENTS_ARTIFACTS_DIR/bin/$bin" >&2
        missing=1
    fi
done
for cfg in attestation-agent.toml cdh.toml; do
    if [[ ! -f "$COCO_GUEST_COMPONENTS_ARTIFACTS_DIR/config/$cfg" ]]; then
        printf '[missing:guest-component-config] %s\n' "$COCO_GUEST_COMPONENTS_ARTIFACTS_DIR/config/$cfg" >&2
        missing=1
    fi
done

if [[ -f "$COCO_SFTP_ROOT/images/kata-containers-cca.img" ]]; then
    if "$COCO_ROOT_DIR/scripts/image/install-guest-components-into-kata-image.sh" --verify-only; then
        :
    else
        missing=1
    fi
fi

if [[ "$missing" -ne 0 ]]; then
    coco_die "COCO-SFTP is missing required runtime files"
fi

coco_log "COCO-SFTP host runtime artifacts and guest image payloads are present"
