#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../install" && pwd)/remote-install-common.sh"

require_root
require_cmd iptables
require_cmd systemctl

missing=0

check_file_present() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        log_install "missing: $file"
        missing=1
    fi
}

check_module_loaded() {
    local module="$1"
    if [[ ! -d "/sys/module/$module" ]] && ! grep -qw "$module" /proc/modules; then
        log_install "module not loaded: $module"
        missing=1
    fi
}

check_service_active() {
    local service="$1"
    if ! systemctl is-active --quiet "$service"; then
        log_install "service not active: $service"
        missing=1
    fi
}

check_file_present /etc/cni/net.d/10-coco-bridge.conflist
check_service_active guest-pull-snapshotter
check_service_active containerd
check_module_loaded overlay
check_module_loaded vsock
check_module_loaded vhost_vsock
check_module_loaded loop

if ! iptables -t nat -C POSTROUTING -s 10.88.0.0/16 ! -o coco0 -j MASQUERADE 2>/dev/null; then
    log_install "missing: coco-bridge NAT rule"
    missing=1
fi

if [[ "$missing" -ne 0 ]]; then
    log_install "image-cache network check failed; run ./scripts/remote/run/prepare-image-cache-network.sh or ./scripts/remote/run/start-container-runtime.sh"
    exit 1
fi

log_install "image-cache network is ready: net=coco-bridge dns=192.168.31.1"
