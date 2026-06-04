#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

GUEST_COMPONENTS_DIR="${GUEST_COMPONENTS_DIR:-$COCO_ROOT_DIR/guest-components}"
DEST_DIR="${DEST_DIR:-$COCO_GUEST_COMPONENTS_ARTIFACTS_DIR/bin}"
CONFIG_DEST_DIR="${CONFIG_DEST_DIR:-$COCO_GUEST_COMPONENTS_ARTIFACTS_DIR/config}"
CONFIG_SOURCE_DIR="${CONFIG_SOURCE_DIR:-$COCO_ROOT_DIR/configs/guest-components}"
TEE_PLATFORM="${TEE_PLATFORM:-cca}"
ARCH="${ARCH:-$COCO_ARCH}"
LIBC="${LIBC:-$COCO_LIBC}"
RUST_TARGET="${RUST_TARGET:-$COCO_RUST_TARGET}"
STRIP_ARTIFACTS="${STRIP_ARTIFACTS:-1}"

coco_require_cmd make cargo install "$COCO_MUSL_CC"
coco_ensure_dir "$DEST_DIR" "$CONFIG_DEST_DIR"

coco_log "building guest-components for $TEE_PLATFORM/$RUST_TARGET"
(
    cd "$GUEST_COMPONENTS_DIR"
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="${COCO_MUSL_CC}"
    CC="${COCO_MUSL_CC}" ARCH="$ARCH" LIBC="$LIBC" make build TEE_PLATFORM="$TEE_PLATFORM"
    cargo build --package confidential-data-hub --bin ttrpc-cdh-tool --target "$RUST_TARGET" --release
    cargo build --package confidential-data-hub --bin vsock-ttrpc-server --target "$RUST_TARGET" --release
)

for bin in "${COCO_GUEST_COMPONENT_BINS[@]}"; do
    coco_install_first_exe "$DEST_DIR/$bin" \
        "$GUEST_COMPONENTS_DIR/target/$RUST_TARGET/release/$bin" \
        "$GUEST_COMPONENTS_DIR/target/$RUST_TARGET/debug/$bin"
    if [[ "$STRIP_ARTIFACTS" == "1" ]]; then
        coco_strip_exe "$DEST_DIR/$bin"
    fi
done

if [[ -f "$CONFIG_SOURCE_DIR/attestation-agent.toml" ]]; then
    coco_install_data "$CONFIG_SOURCE_DIR/attestation-agent.toml" "$CONFIG_DEST_DIR/attestation-agent.toml"
fi
if [[ -f "$CONFIG_SOURCE_DIR/cdh.toml" ]]; then
    coco_install_data "$CONFIG_SOURCE_DIR/cdh.toml" "$CONFIG_DEST_DIR/cdh.toml"
fi

coco_log "guest-components artifacts are ready under $COCO_GUEST_COMPONENTS_ARTIFACTS_DIR"
