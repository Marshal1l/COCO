#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

FIRECRACKER_DIR="${FIRECRACKER_DIR:-$COCO_ROOT_DIR/Firecracker-CCA}"
FIRECRACKER_DEPS_DIR="${FIRECRACKER_DEPS_DIR:-$COCO_ROOT_DIR/firecracker-deps}"
DEST_DIR="${DEST_DIR:-$COCO_SFTP_ROOT/firecracker-bins}"
RUST_TARGET="${RUST_TARGET:-$COCO_RUST_TARGET}"

coco_require_cmd cargo install "$COCO_MUSL_CC"
coco_ensure_dir "$DEST_DIR"

for dep in kvm-bindings kvm-ioctls linux-loader vm-memory; do
    if [[ ! -f "$FIRECRACKER_DEPS_DIR/$dep/Cargo.toml" ]]; then
        coco_die "missing Firecracker dependency $FIRECRACKER_DEPS_DIR/$dep. Restore the firecracker-deps source tree beside Firecracker-CCA before building, or run coco-local-flow.sh --build --skip firecracker to validate the rest of the flow."
    fi
done

coco_log "building Firecracker for $RUST_TARGET"
(
    cd "$FIRECRACKER_DIR"
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="${COCO_MUSL_CC}"
    cargo build --release --target "$RUST_TARGET" -p firecracker
)

artifact_candidates=(
    "$FIRECRACKER_DIR/build/cargo_target/$RUST_TARGET/release/firecracker"
    "$FIRECRACKER_DIR/target/$RUST_TARGET/release/firecracker"
)

artifact=""
for candidate in "${artifact_candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
        artifact="$candidate"
        break
    fi
done

[[ -n "$artifact" ]] || coco_die "Firecracker build completed but no firecracker binary was found"
coco_install_exe "$artifact" "$DEST_DIR/firecracker"
coco_log "Firecracker artifact is ready under $DEST_DIR"
