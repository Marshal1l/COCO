#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/coco_paths.sh"

REPO="${COCO_RELEASE_REPO:-Marshal1l/COCO}"
TAG="${COCO_RELEASE_TAG:-coco-runtime-artifacts}"
TITLE="${COCO_RELEASE_TITLE:-COCO runtime artifacts}"
ASSET_LIST="${ASSET_LIST:-$COCO_ROOT_DIR/scripts/package/coco-release-assets.txt}"

coco_require_cmd gh

coco_release_asset_name() {
    local rel="$1"
    printf '%s' "${rel//\//__}"
}

if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release create "$TAG" \
        --repo "$REPO" \
        --title "$TITLE" \
        --notes "Large runtime artifacts for the COCO workspace. These files are intentionally excluded from git history."
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

assets=()
while IFS= read -r rel || [[ -n "$rel" ]]; do
    [[ -n "$rel" && "${rel:0:1}" != "#" ]] || continue
    file="$COCO_ROOT_DIR/$rel"
    [[ -f "$file" ]] || coco_die "missing release asset: $rel"
    asset_name="$(coco_release_asset_name "$rel")"
    staged="$tmp_dir/$asset_name"
    ln "$file" "$staged" 2>/dev/null || cp -f "$file" "$staged"
    assets+=("$staged")
done < "$ASSET_LIST"

if [[ "${#assets[@]}" -eq 0 ]]; then
    coco_die "no release assets listed in $ASSET_LIST"
fi

gh release upload "$TAG" "${assets[@]}" --repo "$REPO" --clobber
