#!/bin/bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <library-name> <output-path> <artifact-dir>..." >&2
  exit 1
fi

LIB_NAME="$1"
OUTPUT_PATH="$2"
shift 2

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

XCARGS=()
for artifact_dir in "$@"; do
  LIB_PATH="${artifact_dir}/lib${LIB_NAME}.dylib"
  if [[ ! -f "${LIB_PATH}" ]]; then
    echo "Missing library at ${LIB_PATH}" >&2
    exit 1
  fi

  HEADERS_DIR="${artifact_dir}/${LIB_NAME}.swiftmodule"
  if [[ -d "${HEADERS_DIR}" ]]; then
    DEST_HEADERS="${TMP_DIR}/$(basename "${artifact_dir}")-swiftmodule"
    cp -R "${HEADERS_DIR}" "${DEST_HEADERS}"
    XCARGS+=( -library "${LIB_PATH}" -headers "${DEST_HEADERS}" )
  else
    XCARGS+=( -library "${LIB_PATH}" )
  fi

done

xcodebuild -create-xcframework "${XCARGS[@]}" -output "${OUTPUT_PATH}"

