#!/bin/bash

# Builds ChatClientKit for distribution using xcodebuild `build` (not `archive`)
# and assembles a redistributable bundle containing the dylib and Swift module
# interfaces. The resulting zip lands under `.build/distribution/`.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${ROOT_DIR}/.build/experimental_package"
PRODUCTS_ROOT="${BUILD_ROOT}/products"
STAGING_ROOT="${BUILD_ROOT}/staging"
ARCHIVE_NAME="ChatClientKit-maccatalyst"
OUTPUT_ZIP="${ROOT_DIR}/.build/distribution/${ARCHIVE_NAME}.zip"

SCHEME="${SCHEME:-ChatClientKit}"
DESTINATION="${DESTINATION:-generic/platform=macOS,variant=Mac Catalyst}"
CONFIGURATION="${CONFIGURATION:-Release}"

XCBEAUTIFY="$(command -v xcbeautify || true)"

echo "› Preparing build directories…"
rm -rf "${BUILD_ROOT}"
rm -rf "${STAGING_ROOT}"
mkdir -p "${PRODUCTS_ROOT}"
mkdir -p "${STAGING_ROOT}"
mkdir -p "$(dirname "${OUTPUT_ZIP}")"

BUILD_DIR="${BUILD_ROOT}/xcode"
LOG_PIPE_CMD=()
if [[ -n "${XCBEAUTIFY}" ]]; then
  LOG_PIPE_CMD=("$(command -v xcbeautify)")
fi

echo "› Running xcodebuild (scheme: ${SCHEME}, configuration: ${CONFIGURATION})"
set -x
xcodebuild \
  -scheme "${SCHEME}" \
  -destination "${DESTINATION}" \
  -configuration "${CONFIGURATION}" \
  BUILD_DIR="${BUILD_DIR}" \
  build \
  | { [[ ${#LOG_PIPE_CMD[@]} -gt 0 ]] && "${LOG_PIPE_CMD[@]}" || cat; }
set +x

PRODUCTS_PATH="${BUILD_DIR}/Build/Products/${CONFIGURATION}-maccatalyst"
MODULE_DIR="${PRODUCTS_PATH}/ChatClientKit.swiftmodule"

if [[ ! -d "${PRODUCTS_PATH}" ]]; then
  echo "error: build products directory not found: ${PRODUCTS_PATH}" >&2
  exit 1
fi

if [[ ! -d "${MODULE_DIR}" ]]; then
  echo "error: Swift module directory not found: ${MODULE_DIR}" >&2
  exit 1
fi

STAGING="${STAGING_ROOT}/${ARCHIVE_NAME}"
MODULE_STAGING="${STAGING}/Modules/ChatClientKit.swiftmodule"
mkdir -p "${MODULE_STAGING}"

echo "› Collecting build artifacts…"

LIB_PATH="${PRODUCTS_PATH}/libChatClientKit.dylib"
FRAMEWORK_PATH="${PRODUCTS_PATH}/ChatClientKit.framework"

if [[ -f "${LIB_PATH}" ]]; then
  cp "${LIB_PATH}" "${STAGING}/"
elif [[ -d "${FRAMEWORK_PATH}" ]]; then
  mkdir -p "${STAGING}/Frameworks"
  rsync -a --delete "${FRAMEWORK_PATH}/" "${STAGING}/Frameworks/ChatClientKit.framework/"
else
  echo "error: unable to locate ChatClientKit binary (dylib or framework)." >&2
  exit 1
fi

# Copy Swift module metadata
rsync -a --delete "${MODULE_DIR}/" "${MODULE_STAGING}/"

# Copy module map if present (for mixed-language consumers)
MODULE_MAP_DIR="${PRODUCTS_PATH}/ModuleCache.noindex"
if [[ -d "${MODULE_MAP_DIR}" ]]; then
  mkdir -p "${STAGING}/ModuleMaps"
  rsync -a --delete "${MODULE_MAP_DIR}/" "${STAGING}/ModuleMaps/"
fi

echo "› Writing metadata"
cat > "${STAGING}/BUILD_INFO.json" <<'EOF'
{
  "product": "ChatClientKit",
  "platform": "macCatalyst",
  "configuration": "Release",
  "generated_by": "Scripts/experimental_package_build.sh"
}
EOF

echo "› Creating package archive…"
(
  cd "${STAGING_ROOT}" && \
  rm -f "${OUTPUT_ZIP}" && \
  zip -qry "${OUTPUT_ZIP}" "${ARCHIVE_NAME}"
)

echo "✅ Package ready at: ${OUTPUT_ZIP}"

