// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "ChatClientKit",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .macCatalyst(.v17),
    ],
    products: [
        .library(name: "ChatClientKit", type: .dynamic, targets: ["ChatClientKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm/", branch: "main"),
        // 0.5.0+ drops the pure-Swift backend for a Rust artifactbundle that has
        // no Mac Catalyst slice, breaking Catalyst builds. Stay below 0.5.0.
        .package(url: "https://github.com/DePasqualeOrg/swift-tokenizers.git", "0.3.2" ..< "0.5.0"),
    ],
    targets: [
        .target(
            name: "ChatClientKit",
            dependencies: [
                "ServerEvent",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-tokenizers"),
            ]
        ),
        .target(name: "ServerEvent"),
        .testTarget(
            name: "ChatClientKitTests",
            dependencies: ["ChatClientKit"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
