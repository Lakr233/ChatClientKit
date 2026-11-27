#!/bin/bash

# Release tag helpers read against origin so decisions match GitHub.
#
#   ./Script/next-tag.sh binary [short-sha]  xcframework.<short-sha>.<rev>, rev = highest existing + 1
#   ./Script/next-tag.sh exists <tag>        exit 0 if tag exists on origin, 1 if not
#   ./Script/next-tag.sh package             <major>.<minor>.<patch + 1> of highest semver tag

set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f Upstream.versions ]; then
    echo "[!] Repository root not found. Run this script from a full checkout of the repository." >&2
    exit 1
fi

remote_tags() {
    git ls-remote --tags --refs origin | sed 's|.*refs/tags/||'
}

case "${1:-}" in
    binary)
        ref=${2:-$(git rev-parse --short=12 HEAD)}
        prefix="xcframework.$ref."
        pattern="^${prefix//./\\.}[0-9]+$"
        last=$(remote_tags | { grep -E "$pattern" || true; } | sed "s|^$prefix||" | sort -n | tail -1)
        echo "$prefix$((${last:-0} + 1))"
        ;;
    exists)
        tag=${2:-}
        if [ -z "$tag" ]; then
            echo "Usage: $0 exists <tag>" >&2
            exit 1
        fi
        rc=0
        git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null || rc=$?
        case "$rc" in
            0) exit 0 ;;
            2) exit 1 ;;
            *)
                echo "[!] Could not list tags on origin (git exited $rc)." >&2
                exit "$rc"
                ;;
        esac
        ;;
    package)
        last=$(remote_tags | { grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true; } | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
        if [ -z "$last" ]; then
            echo "0.1.0"
            exit 0
        fi
        IFS=. read -r major minor patch <<<"$last"
        echo "$major.$minor.$((patch + 1))"
        ;;
    *)
        echo "Usage: $0 binary [short-sha] | exists <tag> | package" >&2
        exit 1
        ;;
esac
