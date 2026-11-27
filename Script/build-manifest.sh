#!/bin/bash

# Render Package.swift from Package.swift.template with a published xcframework zip and URL.
# Usage: ./Script/build-manifest.sh <xcframework_zip> <download_url>

set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f Upstream.versions ]; then
    echo "[!] Repository root not found. Run this script from a full checkout of the repository." >&2
    exit 1
fi

XCFRAMEWORK_PATH_ZIP=${1:-}
DOWNLOAD_URL=${2:-}

if [ -z "$XCFRAMEWORK_PATH_ZIP" ] || [ -z "$DOWNLOAD_URL" ]; then
    echo "Usage: $0 <xcframework_zip> <download_url>" >&2
    exit 1
fi

if [ ! -f "$XCFRAMEWORK_PATH_ZIP" ]; then
    echo "[!] Archive not found: $XCFRAMEWORK_PATH_ZIP" >&2
    exit 1
fi

SHA256SUM=$(shasum -a 256 "$XCFRAMEWORK_PATH_ZIP" | awk '{print $1}')
echo "[*] SHA256: $SHA256SUM"

PACKAGE_MANIFEST=$(cat Package.swift.template)
PACKAGE_MANIFEST=${PACKAGE_MANIFEST/__DOWNLOAD_URL__/$DOWNLOAD_URL}
PACKAGE_MANIFEST=${PACKAGE_MANIFEST/__CHECKSUM__/$SHA256SUM}

if echo "$PACKAGE_MANIFEST" | grep -q '__'; then
    echo "[!] Package.swift.template has an unexpanded placeholder:" >&2
    echo "$PACKAGE_MANIFEST" | grep -n '__' >&2
    exit 1
fi

printf '%s\n' "$PACKAGE_MANIFEST" >Package.swift
echo "[*] wrote Package.swift"
