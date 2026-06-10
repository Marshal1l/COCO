#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

HOST_KERNEL_DIR="${HOST_KERNEL_DIR:-$COCO_ROOT_DIR/linux-host-kernel}"
HOST_KERNEL_OUT_DIR="${HOST_KERNEL_OUT_DIR:-$HOST_KERNEL_DIR/out/rk3588-host}"
HOST_KERNEL_FRAGMENT="${HOST_KERNEL_FRAGMENT:-$HOST_KERNEL_DIR/coco_host_fragment.config}"
HOST_KERNEL_LOCALVERSION="${HOST_KERNEL_LOCALVERSION-}"
JOBS="${JOBS:-$(nproc)}"
DO_INSTALL=1
DRY_RUN=0
MERGE_FRAGMENT=0
USE_REMOTE_CONFIG=1
FULL_MODULE_BUILD=0
BUILD_TARGETS=(net/netfilter/x_tables.ko net/netfilter/xt_comment.ko)
MODULE_TARGETS=(net/netfilter/xt_comment.ko)
CONFIG_SYMBOLS=(NETFILTER_XT_MATCH_COMMENT)

usage() {
    cat <<EOF
Usage: $0 [options]

Build selected host-kernel modules with a fixed release string and optionally
install them to the running RK3588 host kernel.

Options:
  --module-target PATH   Add an in-tree .ko target to build and install, e.g.
                         net/netfilter/xt_comment.ko.
                         The default install target is net/netfilter/xt_comment.ko.
  --build-target PATH    Add an in-tree .ko target to build only. Use this for
                         modpost dependencies such as net/netfilter/x_tables.ko.
  --config SYMBOL        Force CONFIG_SYMBOL=m before olddefconfig.
                         The default symbol is NETFILTER_XT_MATCH_COMMENT.
  --build-only           Build modules but do not copy them to the remote RK3588.
  --merge-fragment       Merge linux-host-kernel/coco_host_fragment.config.
                         This is off by default to avoid enabling unrelated
                         modules while fixing one missing host module.
  --no-merge-fragment    Keep fragment merging disabled. This is the default.
  --no-remote-config     Reuse the existing HOST_KERNEL_OUT_DIR/.config instead
                         of copying /boot/config-\$(uname -r) from RK3588.
  --full-modules         Run 'make modules' for the whole configured kernel.
                         By default only requested .ko targets are built.
  --dry-run              Print commands without running them.
  -h, --help             Show this help.

Environment:
  HOST_KERNEL_DIR          Default: $HOST_KERNEL_DIR
  HOST_KERNEL_OUT_DIR      Default: $HOST_KERNEL_OUT_DIR
  HOST_KERNEL_FRAGMENT     Default: $HOST_KERNEL_FRAGMENT
  HOST_KERNEL_LOCALVERSION Default: empty string; this suppresses dirty-tree '+'.
  COCO_REMOTE_HOST         Default: $COCO_REMOTE_HOST
  COCO_REMOTE_PASSWORD     Optional SSH password, e.g. root
  COCO_CROSS_COMPILE       Default: $COCO_CROSS_COMPILE
  JOBS                     Default: $JOBS

Important:
  Keep HOST_KERNEL_LOCALVERSION empty unless replacing the host kernel too.
  The RK3588 currently boots 6.12.0-opencca-wip. Building modules without
  LOCALVERSION= can produce 6.12.0-opencca-wip+ and modprobe will reject them.
  The default flow refreshes .config from the running RK3588 kernel first, then
  enables only the requested module symbols, so stale fragment changes do not
  leak into a one-module rebuild.
  The default build is scoped to the requested build targets to avoid a
  slow whole-tree module rebuild for every small fix.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --module-target)
            shift
            [[ $# -gt 0 ]] || coco_die "--module-target requires a value"
            BUILD_TARGETS+=("$1")
            MODULE_TARGETS+=("$1")
            ;;
        --build-target)
            shift
            [[ $# -gt 0 ]] || coco_die "--build-target requires a value"
            BUILD_TARGETS+=("$1")
            ;;
        --config)
            shift
            [[ $# -gt 0 ]] || coco_die "--config requires a value"
            CONFIG_SYMBOLS+=("$1")
            ;;
        --build-only)
            DO_INSTALL=0
            ;;
        --merge-fragment)
            MERGE_FRAGMENT=1
            ;;
        --no-merge-fragment)
            MERGE_FRAGMENT=0
            ;;
        --no-remote-config)
            USE_REMOTE_CONFIG=0
            ;;
        --full-modules)
            FULL_MODULE_BUILD=1
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

if [[ "$MERGE_FRAGMENT" == "1" ]]; then
    FULL_MODULE_BUILD=1
fi

coco_require_cmd make install modinfo "${COCO_CROSS_COMPILE}gcc"
if [[ "$DO_INSTALL" == "1" || "$USE_REMOTE_CONFIG" == "1" ]]; then
    coco_require_cmd ssh scp
    if [[ -n "$COCO_REMOTE_PASSWORD" ]]; then
        coco_require_cmd sshpass
    fi
fi

run_cmd() {
    printf '[coco-host-kernel]'
    printf ' %q' "$@"
    printf '\n'
    if [[ "$DRY_RUN" == "0" ]]; then
        "$@"
    fi
}

module_name_from_target() {
    local target="$1"
    basename "$target" .ko
}

module_path_for_target() {
    local target="$1"
    printf '%s/%s\n' "$HOST_KERNEL_OUT_DIR" "$target"
}

ssh_cmd=(
    ssh
    -p "$COCO_REMOTE_SSH_PORT"
    -oBatchMode=no
    -oStrictHostKeyChecking=accept-new
    -oUserKnownHostsFile=/tmp/coco_known_hosts
)
scp_cmd=(
    scp
    -P "$COCO_REMOTE_SSH_PORT"
    -oBatchMode=no
    -oStrictHostKeyChecking=accept-new
    -oUserKnownHostsFile=/tmp/coco_known_hosts
)
if [[ -n "$COCO_REMOTE_PASSWORD" ]]; then
    ssh_cmd=(sshpass -p "$COCO_REMOTE_PASSWORD" "${ssh_cmd[@]}")
    scp_cmd=(sshpass -p "$COCO_REMOTE_PASSWORD" "${scp_cmd[@]}")
fi

[[ -d "$HOST_KERNEL_DIR" ]] || coco_die "missing host kernel source: $HOST_KERNEL_DIR"
coco_ensure_dir "$HOST_KERNEL_OUT_DIR"

remote_release=""
if [[ "$USE_REMOTE_CONFIG" == "1" ]]; then
    if [[ "$DRY_RUN" == "0" ]]; then
        remote_release="$("${ssh_cmd[@]}" "$COCO_REMOTE_HOST" 'uname -r')"
        remote_config="/boot/config-$remote_release"
        "${ssh_cmd[@]}" "$COCO_REMOTE_HOST" "test -r '$remote_config'" \
            || coco_die "remote kernel config is not readable: $COCO_REMOTE_HOST:$remote_config"
        coco_log "refreshing host kernel .config from $COCO_REMOTE_HOST:$remote_config"
        run_cmd "${scp_cmd[@]}" "$COCO_REMOTE_HOST:$remote_config" "$HOST_KERNEL_OUT_DIR/.config"
    else
        coco_log "dry-run: would refresh host kernel .config from $COCO_REMOTE_HOST:/boot/config-\$(uname -r)"
    fi
elif [[ ! -f "$HOST_KERNEL_OUT_DIR/.config" ]]; then
    coco_log "creating host kernel .config from defconfig"
    run_cmd make -C "$HOST_KERNEL_DIR" O="$HOST_KERNEL_OUT_DIR" ARCH=arm64 \
        CROSS_COMPILE="$COCO_CROSS_COMPILE" LOCALVERSION="$HOST_KERNEL_LOCALVERSION" defconfig
fi

if [[ "$MERGE_FRAGMENT" == "1" && -f "$HOST_KERNEL_FRAGMENT" ]]; then
    run_cmd "$HOST_KERNEL_DIR/scripts/kconfig/merge_config.sh" -m -O "$HOST_KERNEL_OUT_DIR" \
        "$HOST_KERNEL_OUT_DIR/.config" "$HOST_KERNEL_FRAGMENT"
fi

for symbol in "${CONFIG_SYMBOLS[@]}"; do
    run_cmd "$HOST_KERNEL_DIR/scripts/config" --file "$HOST_KERNEL_OUT_DIR/.config" -m "$symbol"
done

run_cmd make -C "$HOST_KERNEL_DIR" O="$HOST_KERNEL_OUT_DIR" ARCH=arm64 \
    CROSS_COMPILE="$COCO_CROSS_COMPILE" LOCALVERSION="$HOST_KERNEL_LOCALVERSION" olddefconfig

if [[ "$DRY_RUN" == "0" ]]; then
    build_release="$(make -s -C "$HOST_KERNEL_DIR" O="$HOST_KERNEL_OUT_DIR" ARCH=arm64 \
        CROSS_COMPILE="$COCO_CROSS_COMPILE" LOCALVERSION="$HOST_KERNEL_LOCALVERSION" kernelrelease)"
    coco_log "build kernelrelease=$build_release"
    if [[ -n "$remote_release" && "$build_release" != "$remote_release" ]]; then
        coco_die "build kernelrelease $build_release does not match remote uname -r $remote_release"
    fi
else
    run_cmd make -s -C "$HOST_KERNEL_DIR" O="$HOST_KERNEL_OUT_DIR" ARCH=arm64 \
        CROSS_COMPILE="$COCO_CROSS_COMPILE" LOCALVERSION="$HOST_KERNEL_LOCALVERSION" kernelrelease
fi

if [[ "$FULL_MODULE_BUILD" == "1" ]]; then
    for target in "${MODULE_TARGETS[@]}"; do
        run_cmd rm -f "$(module_path_for_target "$target")"
    done
    run_cmd make -C "$HOST_KERNEL_DIR" O="$HOST_KERNEL_OUT_DIR" ARCH=arm64 \
        CROSS_COMPILE="$COCO_CROSS_COMPILE" LOCALVERSION="$HOST_KERNEL_LOCALVERSION" -j"$JOBS" modules
else
    for target in "${BUILD_TARGETS[@]}"; do
        run_cmd rm -f "$(module_path_for_target "$target")"
    done
    run_cmd make -C "$HOST_KERNEL_DIR" O="$HOST_KERNEL_OUT_DIR" ARCH=arm64 \
        CROSS_COMPILE="$COCO_CROSS_COMPILE" LOCALVERSION="$HOST_KERNEL_LOCALVERSION" -j"$JOBS" \
        "${BUILD_TARGETS[@]}"
fi

if [[ "$DRY_RUN" == "1" ]]; then
    exit 0
fi

if [[ "$DO_INSTALL" == "1" && -z "$remote_release" ]]; then
    remote_release="$("${ssh_cmd[@]}" "$COCO_REMOTE_HOST" 'uname -r')"
fi

for target in "${MODULE_TARGETS[@]}"; do
    module_path="$(module_path_for_target "$target")"
    [[ -f "$module_path" ]] || coco_die "missing built module: $module_path"

    vermagic="$(modinfo -F vermagic "$module_path" | awk '{print $1}')"
    module_name="$(module_name_from_target "$target")"
    coco_log "$module_name vermagic=$vermagic"

    if [[ "$DO_INSTALL" == "1" && "$DRY_RUN" == "0" && "$vermagic" != "$remote_release" ]]; then
        coco_die "$module_name vermagic $vermagic does not match remote uname -r $remote_release"
    fi
done

if [[ "$DO_INSTALL" == "0" ]]; then
    exit 0
fi

for target in "${MODULE_TARGETS[@]}"; do
    module_path="$(module_path_for_target "$target")"
    module_name="$(module_name_from_target "$target")"
    remote_tmp="/tmp/$module_name.ko"

    run_cmd "${scp_cmd[@]}" "$module_path" "$COCO_REMOTE_HOST:$remote_tmp"
    remote_tmp_q="$(printf '%q' "$remote_tmp")"
    target_q="$(printf '%q' "$target")"
    module_name_q="$(printf '%q' "$module_name")"
    remote_cmd="set -euo pipefail; rel=\$(uname -r); install -D -m 0644 $remote_tmp_q /lib/modules/\$rel/kernel/$target_q; depmod -a \"\$rel\"; modprobe $module_name_q; modinfo $module_name_q | sed -n '1,30p'"
    run_cmd "${ssh_cmd[@]}" "$COCO_REMOTE_HOST" "$remote_cmd"
done
