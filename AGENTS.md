# Maintaining ChatClientKit & XCFramework Packaging

This package ships a prebuilt dynamic `ChatClientKit.xcframework` containing
`ChatClientKit`, `ServerEvent`, `MLX` (`Cmlx` + compiled Metal shaders),
`MLXLLM`, `MLXVLM`, `MLXLMCommon`, and `swift-tokenizers`, trading archive size
for dramatically faster clean builds in consuming apps such as FlowDown.

## Supported Platforms

| Platform | Architectures | Minimum OS |
| --- | --- | --- |
| macOS | `arm64`, `x86_64` | 14.0 |
| iOS | `arm64` | 17.0 |
| iOS Simulator | `arm64`, `x86_64` | 17.0 |
| Mac Catalyst | `arm64`, `x86_64` | 17.0 |

## Package Modes

`Package.swift` resolves in one of three modes:

1. **Source development mode** (`CHATCLIENTKIT_USE_SOURCE=1`, or when no local
   `BinaryTarget/ChatClientKit.xcframework` exists on an unreleased branch):
   compiles `ChatClientKit` from `Sources/` against `mlx-swift-lm`, `mlx-swift`,
   and `swift-tokenizers` and enables internal `ChatClientKitTests`.
2. **Local prebuilt XCFramework mode** (default when
   `BinaryTarget/ChatClientKit.xcframework` exists and `CHATCLIENTKIT_USE_SOURCE`
   is unset): links `BinaryTarget/ChatClientKit.xcframework` with zero external
   SwiftPM dependencies.
3. **Published release mode** (`Package.swift` rendered from
   `Package.swift.template` via `./Script/build-manifest.sh`): downloads the
   versioned `ChatClientKit.xcframework.zip` release asset unless a local
   `BinaryTarget/ChatClientKit.xcframework` overrides it or
   `CHATCLIENTKIT_USE_SOURCE=1` is set.

## Local Build

Requires Xcode (with MetalToolchain installed) and Python 3.

```bash
./Script/build.sh
```

Useful flags:

```bash
./Script/build.sh --platforms macos,maccatalyst
./Script/build.sh --mlx-swift-lm ../mlx-swift-lm   # reuse workspace checkout
./Script/build.sh --package-cache /path/to/SourcePackages
./Script/build.sh --skip-fetch
./Script/build.sh --skip-tests
```

What `./Script/build.sh` does:

1. Fetches pinned `mlx-swift-lm` from `Upstream.versions` into `References/mlx-swift-lm`
   (unless `--mlx-swift-lm` or `--skip-fetch` is supplied).
2. Generates `build/ChatClientKit.xcodeproj` via `Script/assemble.py` with
   `MACH_O_TYPE = mh_dylib` and `BUILD_LIBRARY_FOR_DISTRIBUTION = YES` scoped
   strictly to the `ChatClientKit` target (so internal static SwiftPM
   dependencies do not require library evolution).
3. Archives each platform slice (`macos`, `ios`, `ios-simulator`, `maccatalyst`)
   and stages MLX's compiled `default.metallib` into the framework's native
   resource lookup path (`Versions/A/Resources/default.metallib` for deep
   macOS/Catalyst frameworks; `mlx.metallib` for flat iOS/iOS Simulator
   frameworks), stripping nested `mlx-swift_Cmlx.bundle` copies.
4. Merges slices into `BinaryTarget/ChatClientKit.xcframework`, verifies layout,
   architectures, `.swiftinterface` isolation (no leaked `MLX*`/`Tokenizers`
   imports), and metallib presence via `Script/verify-xcframework.sh`.
5. Packs `build/ChatClientKit.xcframework.zip` with `ditto -c -k --sequesterRsrc --keepParent`
   to preserve deep framework symlinks and re-verifies the unpacked zip.
6. Builds and runs a clean standalone consumer across all slices via
   `Script/test-xcframework-consumer.sh`.

## Why the Framework Is Dynamic

- `ChatClientKit` is shared between an app target and app extensions (such as
  FlowDown and `FlowDownTranslationProvider`), avoiding duplicating MLX/C++
  object code across binaries.
- `ChatClientKit.framework` carries its own bundle directory and Metal shader
  library (`default.metallib` / `mlx.metallib`) so MLX's `load_colocated_library`
  locates shaders without requiring consumers to embed external `.bundle`
  artifacts or link `libc++`, `Metal`, or `Accelerate` manually.
- `ServerEvent` sources are compiled directly into `ChatClientKit` while a thin
  `ServerEvent` shim (`@_exported import ChatClientKit`) keeps existing
  `import ServerEvent` sites compiling.

## CI and Release

Releases split binary creation from package tagging (same model as
`Runestone.xcframework` and `libsolv.xcframework`):

- **Build XCFramework** (`.github/workflows/build-xcframework.yml`): installs
  MetalToolchain, builds and verifies `ChatClientKit.xcframework.zip` across
  all four platforms (including clean consumer verification), runs
  `./Script/test.sh`, publishes binary release tag
  `xcframework.<short-sha>.<rev>`, and optionally dispatches **Release Package**.
- **Release Package** (`.github/workflows/release-package.yml`): downloads an
  existing `xcframework.*` zip, renders `Package.swift` from
  `Package.swift.template` via `./Script/build-manifest.sh`, verifies with
  `./Script/test.sh`, commits `Package.swift`, and creates the semantic package
  release tag.
