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
        .library(name: "ChatClientKit", targets: ["ChatClientKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.21.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", branch: "main"),
        .package(url: "https://github.com/mattt/eventsource.git", from: "1.1.1"),
        .package(path: "../Logger"),
    ],
    targets: [
        .target(
            name: "ChatClientKit",
            dependencies: [
                "ServerEvent",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXVLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                .product(name: "EventSource", package: "EventSource"),
                .product(name: "Logger", package: "Logger"),
            ]
        ),
        .target(name: "ServerEvent", dependencies: [
            .product(name: "Logger", package: "Logger"),
        ]),
        .testTarget(
            name: "ChatClientKitTests",
            dependencies: ["ChatClientKit"]
        ),
    ]
)
