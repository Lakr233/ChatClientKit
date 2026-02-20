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
        .package(url: "https://github.com/ml-explore/mlx-swift-lm/", from: "2.30.6"),
    ],
    targets: [
        .target(
            name: "ChatClientKit",
            dependencies: [
                "ServerEvent",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
        ),
        .target(name: "ServerEvent"),
        .testTarget(
            name: "ChatClientKitTests",
            dependencies: ["ChatClientKit"],
        ),
    ],
)
