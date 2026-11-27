#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f Upstream.versions ]; then
    echo "[!] Repository root not found. Run this script from a full checkout of the repository." >&2
    exit 1
fi

usage() {
    cat <<'EOF'
Usage: ./Script/build.sh [options]

Options:
  --platforms <csv>        Platform slices to build.
                           Default: macos,ios,iossimulator,maccatalyst
  --mlx-swift-lm <path>    Reuse an existing mlx-swift-lm checkout instead of fetching ./References/mlx-swift-lm
  --package-cache <path>   Reuse an existing SwiftPM clonedSourcePackagesDirPath
  --skip-fetch             Reuse existing ./References/mlx-swift-lm checkout
  --skip-tests             Skip consumer verification
  -h, --help               Show this help

Notes:
  - Assembles ChatClientKit with MLX, mlx-swift-lm, swift-tokenizers, and ServerEvent
    baked into a self-contained dynamic ChatClientKit.xcframework
  - Output: BinaryTarget/ChatClientKit.xcframework and build/ChatClientKit.xcframework.zip
  - Package.swift automatically picks up BinaryTarget/ChatClientKit.xcframework when present;
    set CHATCLIENTKIT_USE_SOURCE=1 to build from source
EOF
}

PLATFORMS="macos,ios,iossimulator,maccatalyst"
MLX_SWIFT_LM_PATH=""
PACKAGE_CACHE_PATH=""
SKIP_FETCH=0
SKIP_TESTS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --platforms)
            PLATFORMS="$2"
            shift 2
            ;;
        --mlx-swift-lm)
            MLX_SWIFT_LM_PATH="$2"
            SKIP_FETCH=1
            shift 2
            ;;
        --package-cache)
            PACKAGE_CACHE_PATH="$2"
            shift 2
            ;;
        --skip-fetch)
            SKIP_FETCH=1
            shift
            ;;
        --skip-tests)
            SKIP_TESTS=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "[!] Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

ROOT_DIR=$PWD
ARCHIVE_DIR="$ROOT_DIR/build/archives"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
XCFRAMEWORK="$ROOT_DIR/BinaryTarget/ChatClientKit.xcframework"
ZIP_PATH="$ROOT_DIR/build/ChatClientKit.xcframework.zip"

if [ -z "$MLX_SWIFT_LM_PATH" ]; then
    MLX_SWIFT_LM_PATH="$ROOT_DIR/References/mlx-swift-lm"
fi

if [ "$SKIP_FETCH" -eq 0 ]; then
    ./Script/fetch-upstream.sh
fi

python3 ./Script/assemble.py --root "$ROOT_DIR" --mlx-swift-lm "$MLX_SWIFT_LM_PATH"

rm -rf "$ARCHIVE_DIR" "$DERIVED_DATA" "$XCFRAMEWORK" "$ZIP_PATH"
mkdir -p "$ARCHIVE_DIR" "$(dirname "$XCFRAMEWORK")"

format_output() {
    if command -v xcbeautify >/dev/null 2>&1; then
        xcbeautify --disable-colored-output --disable-logging
    else
        cat
    fi
}

COMMON_PKG_ARGS=()
if [ -n "$PACKAGE_CACHE_PATH" ]; then
    COMMON_PKG_ARGS+=("-clonedSourcePackagesDirPath" "$PACKAGE_CACHE_PATH")
fi

echo "[*] resolving SwiftPM packages for ChatClientKit.xcodeproj"
if ! xcodebuild \
    -project "$ROOT_DIR/build/ChatClientKit.xcodeproj" \
    -scheme ChatClientKit \
    -derivedDataPath "$DERIVED_DATA" \
    -skipMacroValidation \
    -skipPackagePluginValidation \
    "${COMMON_PKG_ARGS[@]+"${COMMON_PKG_ARGS[@]}"}" \
    -resolvePackageDependencies 2>&1 | format_output; then
    echo "[!] Package resolution failed." >&2
    exit 1
fi

stage_metallib() {
    local slice_name="$1"
    local build_products_subdir="$2"
    local uninstalled_subdir="$3"
    local framework="$4"

    local metallib=""
    local archive_intermediates="$DERIVED_DATA/Build/Intermediates.noindex/ArchiveIntermediates/ChatClientKit"
    local search_roots=(
        "$framework"
        "$archive_intermediates/IntermediateBuildFilesPath/UninstalledProducts/$uninstalled_subdir"
        "$archive_intermediates/BuildProductsPath/$build_products_subdir"
        "$DERIVED_DATA/Build/Products/$build_products_subdir"
    )

    for search_root in "${search_roots[@]}"; do
        if [ -d "$search_root" ]; then
            metallib=$(find "$search_root" -path "*mlx-swift_Cmlx.bundle*" -name "default.metallib" -type f | head -1 || true)
            if [ -n "$metallib" ]; then
                break
            fi
        fi
    done

    if [ -z "$metallib" ] || [ ! -f "$metallib" ]; then
        echo "[!] Missing compiled MLX default.metallib for $slice_name" >&2
        find "$DERIVED_DATA/Build" -name "*.metallib" -print >&2 || true
        exit 1
    fi

    # Remove any nested SwiftPM resource bundle copied into the framework so we
    # ship a single clean metallib without nested bundle codesign hazards.
    find "$framework" -name "mlx-swift_Cmlx.bundle" -type d -prune -exec rm -rf {} +

    # mlx's device.cpp looks for:
    #   1. <binary_dir>/mlx.metallib         (flat iOS/iOS Simulator framework root)
    #   2. <binary_dir>/Resources/default.metallib (deep macOS/Mac Catalyst bundle)
    case "$slice_name" in
        macos | maccatalyst)
            mkdir -p "$framework/Versions/A/Resources"
            cp "$metallib" "$framework/Versions/A/Resources/default.metallib"
            echo "[*] staged $slice_name metallib -> Versions/A/Resources/default.metallib ($(du -h "$metallib" | awk '{print $1}'))"
            ;;
        ios | ios-simulator)
            cp "$metallib" "$framework/mlx.metallib"
            echo "[*] staged $slice_name metallib -> mlx.metallib ($(du -h "$metallib" | awk '{print $1}'))"
            ;;
        *)
            echo "[!] Unhandled slice for metallib staging: $slice_name" >&2
            exit 1
            ;;
    esac
}

archive_platform() {
    local name="$1"
    local destination="$2"
    local build_products_subdir="$3"
    local uninstalled_subdir="$4"
    local extra_archs="${5:-}"
    local archive_path="$ARCHIVE_DIR/$name.xcarchive"

    echo "[*] archiving $name ($destination)"
    # IMPORTANT: Do NOT pass BUILD_LIBRARY_FOR_DISTRIBUTION=YES on the CLI here.
    # It is set strictly on the ChatClientKit target inside project.pbxproj so
    # static SwiftPM dependencies (mlx-swift, mlx-swift-lm, swift-tokenizers) do
    # not inherit library evolution mode.
    local command=(
        xcodebuild archive
        -project "$ROOT_DIR/build/ChatClientKit.xcodeproj"
        -scheme ChatClientKit
        -destination "$destination"
        -archivePath "$archive_path"
        -derivedDataPath "$DERIVED_DATA"
        -configuration Release
        -skipMacroValidation
        -skipPackagePluginValidation
        "${COMMON_PKG_ARGS[@]+"${COMMON_PKG_ARGS[@]}"}"
        SKIP_INSTALL=NO
        ONLY_ACTIVE_ARCH=NO
        COMPILER_INDEX_STORE_ENABLE=NO
        CODE_SIGNING_ALLOWED=NO
        CODE_SIGNING_REQUIRED=NO
        CODE_SIGN_IDENTITY=""
    )
    if [ -n "$extra_archs" ]; then
        command+=(ARCHS="$extra_archs")
    fi

    if ! "${command[@]}" 2>&1 | format_output; then
        echo "[!] The $name archive failed. Check the build output above." >&2
        exit 1
    fi

    local framework="$archive_path/Products/Library/Frameworks/ChatClientKit.framework"
    if [ ! -d "$framework" ]; then
        echo "[!] The $name build did not produce ChatClientKit.framework." >&2
        find "$archive_path/Products" -maxdepth 5 -print >&2
        exit 1
    fi

    stage_metallib "$name" "$build_products_subdir" "$uninstalled_subdir" "$framework"
    XCFRAMEWORK_ARGS+=("-framework" "$framework")
}

XCFRAMEWORK_ARGS=()
IFS=',' read -r -a PLATFORM_LIST <<<"$PLATFORMS"
for platform in "${PLATFORM_LIST[@]}"; do
    case "$platform" in
        macos)
            archive_platform "macos" "generic/platform=macOS" "Release" "macosx" "arm64 x86_64"
            ;;
        ios)
            archive_platform "ios" "generic/platform=iOS" "Release-iphoneos" "iphoneos" "arm64"
            ;;
        iossimulator)
            archive_platform "ios-simulator" "generic/platform=iOS Simulator" "Release-iphonesimulator" "iphonesimulator" "arm64 x86_64"
            ;;
        maccatalyst)
            archive_platform "maccatalyst" "generic/platform=macOS,variant=Mac Catalyst" "Release-maccatalyst" "macosx" "arm64 x86_64"
            ;;
        *)
            echo "[!] Unknown platform: $platform. Run ./Script/build.sh --help for the supported platforms." >&2
            exit 1
            ;;
    esac
done

echo "[*] creating xcframework"
xcodebuild -create-xcframework \
    "${XCFRAMEWORK_ARGS[@]}" \
    -output "$XCFRAMEWORK"

cp LICENSE "$XCFRAMEWORK/"
cp Upstream.versions "$XCFRAMEWORK/"

./Script/verify-xcframework.sh "$XCFRAMEWORK"

echo "[*] packing $ZIP_PATH (preserving symlinks)"
(
    cd "$(dirname "$XCFRAMEWORK")"
    ditto -c -k --sequesterRsrc --keepParent "$(basename "$XCFRAMEWORK")" "$(basename "$ZIP_PATH")"
)
mv "$(dirname "$XCFRAMEWORK")/$(basename "$ZIP_PATH")" "$ZIP_PATH"

./Script/verify-xcframework.sh "$ZIP_PATH"

if [ "$SKIP_TESTS" -eq 0 ]; then
    ./Script/test-xcframework-consumer.sh "$XCFRAMEWORK"
fi

echo "[*] build complete"
echo "    $XCFRAMEWORK ($(du -sh "$XCFRAMEWORK" | awk '{print $1}'))"
echo "    $ZIP_PATH ($(du -h "$ZIP_PATH" | awk '{print $1}'))"
