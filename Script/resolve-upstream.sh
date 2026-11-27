#!/bin/bash

# Resolves mlx-swift-lm to the commit ChatClientKit.xcframework should be built against.
#
#   ./Script/resolve-upstream.sh                 the pin in Upstream.versions
#   ./Script/resolve-upstream.sh latest          HEAD of origin/main on MLX_SWIFT_LM_REPO
#   ./Script/resolve-upstream.sh <sha|tag>       that commit or tag
#   ./Script/resolve-upstream.sh latest --write  also rewrite MLX_SWIFT_LM_REF in Upstream.versions
#
# stdout is eval-able: MLX_SWIFT_LM_REF=<sha>. Everything else goes to stderr.

set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f Upstream.versions ]; then
    echo "[!] Repository root not found. Run this script from a full checkout of the repository." >&2
    exit 1
fi

# shellcheck disable=SC1091
source ./Upstream.versions

REQUESTED=""
WRITE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --write) WRITE=1 ;;
        *) REQUESTED="$1" ;;
    esac
    shift
done

if [ -z "$REQUESTED" ]; then
    REF="$MLX_SWIFT_LM_REF"
elif [ "$REQUESTED" = "latest" ]; then
    REF=$(git ls-remote "$MLX_SWIFT_LM_REPO" refs/heads/main | awk '{print $1}')
elif echo "$REQUESTED" | grep -Eq '^[0-9a-f]{40}$'; then
    REF="$REQUESTED"
else
    TAGS=$(git ls-remote --tags "$MLX_SWIFT_LM_REPO")
    REF=$(echo "$TAGS" | awk -v t="refs/tags/$REQUESTED^{}" '$2 == t { print $1 }')
    if [ -z "$REF" ]; then
        REF=$(echo "$TAGS" | awk -v t="refs/tags/$REQUESTED" '$2 == t { print $1 }')
    fi
fi

if ! echo "${REF:-}" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "[!] Failed to resolve mlx-swift-lm ref for '${REQUESTED:-pinned}': got '${REF:-empty}'" >&2
    exit 1
fi

echo "MLX_SWIFT_LM_REF=$REF"

if [ "$WRITE" -eq 1 ]; then
    sed -e "s|^MLX_SWIFT_LM_REF=.*|MLX_SWIFT_LM_REF=$REF|" \
        Upstream.versions >Upstream.versions.tmp
    mv Upstream.versions.tmp Upstream.versions
    echo "[*] Upstream.versions pinned to mlx-swift-lm $REF" >&2
fi
