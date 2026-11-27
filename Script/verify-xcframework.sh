#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f Upstream.versions ]; then
    echo "[!] Repository root not found. Run this script from a full checkout of the repository." >&2
    exit 1
fi

INPUT_PATH=${1:-}
if [ -z "$INPUT_PATH" ]; then
    echo "Usage: $0 <xcframework_or_zip>" >&2
    exit 1
fi

if [ ! -e "$INPUT_PATH" ]; then
    echo "[!] Path not found: $INPUT_PATH" >&2
    exit 1
fi

TEMP_DIR=""
XCFRAMEWORK_PATH="$INPUT_PATH"

cleanup() {
    if [ -n "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

if [[ "$INPUT_PATH" == *.zip ]]; then
    python3 - "$INPUT_PATH" <<'ZIPCHECK'
import sys, zipfile
zip_path = sys.argv[1]
with zipfile.ZipFile(zip_path) as zf:
    names = zf.namelist()
    if not names:
        raise SystemExit(f"[!] Empty zip archive: {zip_path}")
    for name in names:
        if name.startswith("__MACOSX/") or "/.DS_Store" in name or name.endswith(".DS_Store") or "_CodeSignature" in name:
            raise SystemExit(f"[!] Unwanted entry in zip archive: {name}")
        if not name.startswith("ChatClientKit.xcframework/"):
            raise SystemExit(f"[!] Unexpected top-level entry in zip archive: {name}")
print(f"[*] verified zip cleanliness ({len(names)} entries): {zip_path}")
ZIPCHECK
    TEMP_DIR=$(mktemp -d)
    ditto -x -k "$INPUT_PATH" "$TEMP_DIR"
    XCFRAMEWORK_PATH=$(find "$TEMP_DIR" -maxdepth 1 -name "*.xcframework" -type d | head -1)
fi

if [ -z "$XCFRAMEWORK_PATH" ] || [ ! -d "$XCFRAMEWORK_PATH" ]; then
    echo "[!] No xcframework found in $INPUT_PATH" >&2
    exit 1
fi

python3 - "$XCFRAMEWORK_PATH" <<'PY'
import os
import plistlib
import re
import subprocess
import sys

xcframework = sys.argv[1]
info_path = os.path.join(xcframework, "Info.plist")
if not os.path.isfile(info_path):
    raise SystemExit(f"[!] Missing Info.plist: {info_path}")

with open(info_path, "rb") as handle:
    info = plistlib.load(handle)

libraries = info.get("AvailableLibraries")
if not isinstance(libraries, list) or not libraries:
    raise SystemExit("[!] XCFramework lists no libraries.")

expected = {
    ("macos", None): ({"arm64", "x86_64"}, "14.0"),
    ("ios", None): ({"arm64"}, "17.0"),
    ("ios", "simulator"): ({"arm64", "x86_64"}, "17.0"),
    ("ios", "maccatalyst"): ({"arm64", "x86_64"}, "17.0"),
}

home_dir = os.path.expanduser("~")
forbidden_path_prefixes = [p for p in (home_dir, "/Users/") if p and p != "/"]

forbidden_imports = {
    "Cmlx",
    "Jinja",
    "MLX",
    "MLXFast",
    "MLXFFT",
    "MLXLinalg",
    "MLXLLM",
    "MLXLMCommon",
    "MLXNN",
    "MLXOptimizers",
    "MLXRandom",
    "MLXVLM",
    "Numerics",
    "ServerEvent",
    "Tokenizers",
    "TokenizersCore",
    "TokenizersRust",
    "TokenizersSwiftBackend",
    "yyjson",
}

import_re = re.compile(r"^\s*(?:@_exported\s+)?import\s+([A-Za-z0-9_]+)\b", re.MULTILINE)

for library in libraries:
    identifier = library.get("LibraryIdentifier")
    library_path = library.get("LibraryPath")
    platform = library.get("SupportedPlatform")
    platform_variant = library.get("SupportedPlatformVariant")
    declared = set(library.get("SupportedArchitectures", []))

    if not identifier or library_path != "ChatClientKit.framework":
        raise SystemExit(f"[!] Malformed library metadata: {library}")
    if (platform, platform_variant) not in expected:
        raise SystemExit(f"[!] Unsupported slice ({platform}, {platform_variant}) in {identifier}")

    framework = os.path.join(xcframework, identifier, library_path)
    binary = os.path.join(framework, "ChatClientKit")
    if not os.path.isdir(framework):
        raise SystemExit(f"[!] Missing framework directory: {framework}")
    if not os.path.isfile(binary):
        raise SystemExit(f"[!] Missing framework binary: {binary}")

    is_deep = platform == "macos" or platform_variant == "maccatalyst"
    if is_deep:
        for link_name in ("ChatClientKit", "Modules", "Resources", os.path.join("Versions", "Current")):
            link_path = os.path.join(framework, link_name)
            if not os.path.islink(link_path):
                raise SystemExit(f"[!] Expected symlink in deep framework layout: {link_path}")
        fw_info_path = os.path.join(framework, "Versions", "A", "Resources", "Info.plist")
        metallib_path = os.path.join(framework, "Versions", "A", "Resources", "default.metallib")
    else:
        fw_info_path = os.path.join(framework, "Info.plist")
        metallib_path = os.path.join(framework, "mlx.metallib")

    if not os.path.isfile(fw_info_path):
        raise SystemExit(f"[!] Missing framework Info.plist: {fw_info_path}")

    with open(fw_info_path, "rb") as handle:
        fw_info = plistlib.load(handle)

    min_key = "LSMinimumSystemVersion" if is_deep else "MinimumOSVersion"
    if not fw_info.get(min_key):
        raise SystemExit(f"[!] {identifier} Info.plist is missing {min_key}")

    kind = subprocess.check_output(["file", "-b", binary], text=True)
    if "dynamically linked shared library" not in kind:
        raise SystemExit(f"[!] {identifier} is not a dynamic library ({kind.strip()}).")

    actual = set(subprocess.check_output(["lipo", "-archs", binary], text=True).split())
    if actual != declared:
        raise SystemExit(f"[!] {identifier} arch mismatch: Info.plist={sorted(declared)} binary={sorted(actual)}")
    wanted, expected_minos = expected[(platform, platform_variant)]
    if actual != wanted:
        print(f"[*] note: {identifier} architectures {sorted(actual)} (expected {sorted(wanted)})", file=sys.stderr)

    # Verify install name (LC_ID_DYLIB) and zero non-system dylib dependencies.
    expected_install_name = (
        "@rpath/ChatClientKit.framework/Versions/A/ChatClientKit"
        if is_deep
        else "@rpath/ChatClientKit.framework/ChatClientKit"
    )
    install_names = [
        line.strip()
        for line in subprocess.check_output(["otool", "-D", binary], text=True).splitlines()
        if line.strip() and not line.strip().endswith(":")
    ]
    if not install_names or any(name != expected_install_name for name in install_names):
        raise SystemExit(f"[!] {identifier} unexpected LC_ID_DYLIB: {install_names} (expected {expected_install_name})")

    otool_l = subprocess.check_output(["otool", "-L", binary], text=True).splitlines()
    for line in otool_l:
        stripped = line.strip()
        if not stripped or stripped.endswith(":"):
            continue
        dep = stripped.split(" (", 1)[0]
        if dep == expected_install_name:
            continue
        if dep.startswith(("/usr/lib/", "/System/Library/", "@rpath/libswift")):
            continue
        raise SystemExit(f"[!] {identifier} links non-system dylib: {dep}")

    # Verify minimum OS version in Mach-O LC_BUILD_VERSION load commands.
    minos_values = []
    in_build_ver = False
    for line in subprocess.check_output(["otool", "-l", binary], text=True).splitlines():
        s = line.strip()
        if s == "cmd LC_BUILD_VERSION":
            in_build_ver = True
        elif in_build_ver and s.startswith("minos "):
            minos_values.append(s.split()[1])
            in_build_ver = False
    if not minos_values or any(v != expected_minos for v in minos_values):
        raise SystemExit(f"[!] {identifier} unexpected LC_BUILD_VERSION minos={minos_values} (expected {expected_minos})")

    # Verify no local build-machine paths leaked into binary strings or swiftinterfaces.
    raw_binary = open(os.path.realpath(binary), "rb").read()
    for prefix in forbidden_path_prefixes:
        if prefix.encode("utf-8") in raw_binary:
            raise SystemExit(f"[!] {identifier} binary contains leaked host path prefix: {prefix}")

    swiftmodule = os.path.join(framework, "Modules", "ChatClientKit.swiftmodule")
    if not os.path.isdir(swiftmodule):
        raise SystemExit(f"[!] {identifier} is missing ChatClientKit.swiftmodule")

    interfaces = [f for f in os.listdir(swiftmodule) if f.endswith(".swiftinterface") and not f.endswith(".private.swiftinterface")]
    if not interfaces:
        raise SystemExit(f"[!] {identifier} is missing .swiftinterface files (BUILD_LIBRARY_FOR_DISTRIBUTION=YES)")

    for iface in sorted(interfaces):
        iface_path = os.path.join(swiftmodule, iface)
        content = open(iface_path, encoding="utf-8").read()
        leaked = sorted(set(import_re.findall(content)) & forbidden_imports)
        if leaked:
            raise SystemExit(f"[!] {identifier}/{iface} leaked internal imports: {leaked}")
        for prefix in forbidden_path_prefixes:
            if prefix in content:
                raise SystemExit(f"[!] {identifier}/{iface} leaked host path prefix: {prefix}")

    if not os.path.isfile(metallib_path) or os.path.getsize(metallib_path) == 0:
        raise SystemExit(f"[!] {identifier} is missing non-empty MLX metallib at {metallib_path}")

    for dirpath, dirnames, filenames in os.walk(framework):
        if "mlx-swift_Cmlx.bundle" in dirnames:
            raise SystemExit(f"[!] {identifier} still contains nested mlx-swift_Cmlx.bundle in {dirpath}")
        if "_CodeSignature" in dirnames:
            raise SystemExit(f"[!] {identifier} contains unexpected _CodeSignature in {dirpath}")
        if ".DS_Store" in filenames:
            raise SystemExit(f"[!] {identifier} contains .DS_Store in {dirpath}")

    size_mb = os.path.getsize(os.path.realpath(binary)) / (1024 * 1024)
    metal_mb = os.path.getsize(metallib_path) / (1024 * 1024)
    print(f"[*] slice {identifier}: archs={','.join(sorted(actual))} minos={expected_minos} dylib={size_mb:.1f}MB metallib={metal_mb:.1f}MB interfaces={len(interfaces)}")

print(f"[*] verified xcframework: {xcframework}")
PY
