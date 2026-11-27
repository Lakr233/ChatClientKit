#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f Upstream.versions ]; then
    echo "[!] Repository root not found. Run this script from a full checkout of the repository." >&2
    exit 1
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/chatclientkit-clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/chatclientkit-swiftpm-module-cache}"
DERIVED_DATA="${DERIVED_DATA:-$PWD/build/TestDerivedData}"

format_output() {
    if command -v xcbeautify >/dev/null 2>&1; then
        xcbeautify --disable-colored-output --disable-logging
    else
        cat
    fi
}

run() {
    echo "[*] $*"
    if ! "$@" 2>&1 | format_output; then
        echo "[!] Step failed." >&2
        exit 1
    fi
}

for destination in \
    "generic/platform=macOS" \
    "generic/platform=iOS" \
    "generic/platform=iOS Simulator" \
    "generic/platform=macOS,variant=Mac Catalyst"; do
    run xcodebuild \
        -scheme ChatClientKit-Package \
        -destination "$destination" \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        build
done

for destination in \
    "platform=macOS" \
    "platform=macOS,variant=Mac Catalyst"; do
    run xcodebuild \
        -scheme ChatClientKit-Package \
        -destination "$destination" \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        test
done

echo "[*] all package binary tests passed"
