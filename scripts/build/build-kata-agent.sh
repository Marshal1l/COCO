#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

AGENT_DIR="${AGENT_DIR:-$COCO_ROOT_DIR/kata-containers-cca/src/agent}"
DEST_DIR="${DEST_DIR:-$COCO_ARTIFACTS_ROOT/kata-agent/bin}"
RUST_TARGET="${RUST_TARGET:-$COCO_RUST_TARGET}"
STRIP_ARTIFACTS="${STRIP_ARTIFACTS:-1}"

coco_require_cmd cargo install "$COCO_MUSL_CC"
coco_ensure_dir "$DEST_DIR"

coco_log "building Kata guest agent for $RUST_TARGET"
(
    cd "$AGENT_DIR"
    make src/version.rs
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="${COCO_MUSL_CC}"
    cargo build --features guest-pull --release --target "$RUST_TARGET" --bin kata-agent
)

coco_install_exe "$AGENT_DIR/target/$RUST_TARGET/release/kata-agent" "$DEST_DIR/kata-agent"
if [[ "$STRIP_ARTIFACTS" == "1" ]]; then
    coco_strip_exe "$DEST_DIR/kata-agent"
fi

coco_log "Kata guest agent artifact is ready at $DEST_DIR/kata-agent"
