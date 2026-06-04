#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

REPO="${COCO_RELEASE_REPO:-Marshal1l/COCO}"
TAG="${COCO_RELEASE_TAG:-coco-runtime-artifacts}"
ASSET_LIST="${ASSET_LIST:-$COCO_ROOT_DIR/scripts/package/coco-release-assets.txt}"

coco_require_cmd gh

coco_release_asset_name() {
    local rel="$1"
    printf '%s' "${rel//\//__}"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

while IFS= read -r rel || [[ -n "$rel" ]]; do
    [[ -n "$rel" && "${rel:0:1}" != "#" ]] || continue
    asset="$(coco_release_asset_name "$rel")"
    dst="$COCO_ROOT_DIR/$rel"
    rm -f "$tmp_dir/$asset"
    mkdir -p "$COCO_ROOT_DIR/$(dirname "$rel")"
    coco_log "downloading $asset to $rel"
    gh release download "$TAG" \
        --repo "$REPO" \
        --pattern "$asset" \
        --clobber \
        --dir "$tmp_dir"
    [[ -f "$tmp_dir/$asset" ]] || coco_die "missing downloaded asset: $asset"
    install -D -m0644 "$tmp_dir/$asset" "$dst"
done < "$ASSET_LIST"
