#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f Upstream.versions ]; then
    echo "[!] Repository root not found. Run this script from a full checkout of the repository." >&2
    exit 1
fi

# shellcheck disable=SC1091
source ./Upstream.versions

REFERENCES_DIR=${1:-"$PWD/References"}
mkdir -p "$REFERENCES_DIR"

clone_pinned() {
    local name="$1"
    local repo="$2"
    local ref="$3"
    local dest="$REFERENCES_DIR/$name"

    if [ ! -d "$dest/.git" ]; then
        rm -rf "$dest"
        git init -q "$dest"
        git -C "$dest" remote add origin "$repo"
    fi

    if [ "$(git -C "$dest" remote get-url origin)" != "$repo" ]; then
        git -C "$dest" remote set-url origin "$repo"
    fi

    echo "[*] fetching $name ($repo @ $ref)"
    if ! git -C "$dest" cat-file -e "$ref^{commit}" 2>/dev/null; then
        git -C "$dest" fetch --depth 1 origin "$ref" 2>/dev/null || git -C "$dest" fetch origin "$ref"
    fi
    git -C "$dest" checkout --detach --force "$ref"

    local resolved
    resolved=$(git -C "$dest" rev-parse HEAD)
    if [ "$resolved" != "$ref" ]; then
        echo "[!] $name resolved to $resolved, but the pin is $ref. Update Upstream.versions or check the remote." >&2
        exit 1
    fi
}

clone_pinned "mlx-swift-lm" "$MLX_SWIFT_LM_REPO" "$MLX_SWIFT_LM_REF"

echo "[*] upstream checkout ready in $REFERENCES_DIR"
