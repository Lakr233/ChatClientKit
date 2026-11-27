// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localXCFramework = "BinaryTarget/ChatClientKit.xcframework"
let hasLocalXCFramework = FileManager.default.fileExists(
    atPath: packageRoot.appendingPathComponent(localXCFramework).path
)
let useSource = ProcessInfo.processInfo.environment["CHATCLIENTKIT_USE_SOURCE"] == "1"

let package: Package
if useSource {
    package = Package(
        name: "ChatClientKit",
        defaultLocalization: "en",
        platforms: [
            .macOS(.v14),
            .iOS(.v17),
            .macCatalyst(.v17),
        ],
        products: [
            .library(name: "ChatClientKit", type: .dynamic, targets: ["ChatClientKit"]),
            .library(name: "ServerEvent", targets: ["ServerEvent"]),
        ],
        dependencies: [
            .package(url: "https://github.com/ml-explore/mlx-swift-lm/", branch: "main"),
            .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.33.0")),
            // 0.5.0+ drops the pure-Swift backend for a Rust artifactbundle that has
            // no Mac Catalyst slice, breaking Catalyst builds. Stay below 0.5.0.
            .package(url: "https://github.com/DePasqualeOrg/swift-tokenizers.git", "0.3.2" ..< "0.5.0"),
        ],
        targets: [
            .target(
                name: "ChatClientKit",
                dependencies: [
                    .product(name: "MLX", package: "mlx-swift"),
                    .product(name: "MLXLLM", package: "mlx-swift-lm"),
                    .product(name: "MLXVLM", package: "mlx-swift-lm"),
                    .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                    .product(name: "Tokenizers", package: "swift-tokenizers"),
                ]
            ),
            .target(
                name: "ServerEvent",
                dependencies: ["ChatClientKit"]
            ),
            .testTarget(
                name: "ChatClientKitTests",
                dependencies: ["ChatClientKit", "ServerEvent"],
                resources: [
                    .copy("Fixtures"),
                ]
            ),
            .testTarget(
                name: "ChatClientKitBinaryTests",
                dependencies: ["ChatClientKit", "ServerEvent"]
            ),
        ]
    )
} else {
    let binaryTarget: Target = hasLocalXCFramework
        ? .binaryTarget(name: "ChatClientKit", path: localXCFramework)
        : .binaryTarget(
            name: "ChatClientKit",
            url: "https://github.com/Lakr233/ChatClientKit/releases/download/xcframework.577eb77a4110.1/ChatClientKit.xcframework.zip",
            checksum: "34a612ea2262090c3f01f3d1382d2932353404490b7990b3a3e7173ba0b4487c"
        )

    package = Package(
        name: "ChatClientKit",
        defaultLocalization: "en",
        platforms: [
            .macOS(.v14),
            .iOS(.v17),
            .macCatalyst(.v17),
        ],
        products: [
            .library(name: "ChatClientKit", targets: ["ChatClientKit"]),
            .library(name: "ServerEvent", targets: ["ServerEvent"]),
        ],
        targets: [
            binaryTarget,
            .target(
                name: "ServerEvent",
                dependencies: ["ChatClientKit"]
            ),
            .testTarget(
                name: "ChatClientKitBinaryTests",
                dependencies: ["ChatClientKit", "ServerEvent"]
            ),
        ]
    )
}
