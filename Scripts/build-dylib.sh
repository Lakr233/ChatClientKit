#!/bin/bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <architecture> <output-directory>" >&2
  exit 1
fi

ARCH="$1"
OUTPUT_DIR="$2"
LIB_NAME="ChatClientKit"

BUILD_TRIPLE="${ARCH}-apple-macosx"

swift build -c release --arch "${ARCH}" --triple "${BUILD_TRIPLE}"

BUILD_DIR=".build/${BUILD_TRIPLE}/release"
LIB_PATH="${BUILD_DIR}/lib${LIB_NAME}.dylib"

if [[ ! -f "${LIB_PATH}" ]]; then
  echo "Expected library not found at ${LIB_PATH}" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
cp "${LIB_PATH}" "${OUTPUT_DIR}/"

shopt -s nullglob
for metadata in "${BUILD_DIR}/${LIB_NAME}".*; do
  if [[ -e "${metadata}" ]]; then
    cp -R "${metadata}" "${OUTPUT_DIR}/"
  fi
done
shopt -u nullglob

