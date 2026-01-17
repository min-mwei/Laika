// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LaikaModel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LaikaModel", targets: ["LaikaModel"])
    ],
    dependencies: [
        .package(path: "../shared"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMinor(from: "2.29.1"))
    ],
    targets: [
        .target(
            name: "LaikaModel",
            dependencies: [
                .product(name: "LaikaShared", package: "shared"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm")
            ]
        ),
        .testTarget(name: "LaikaModelTests", dependencies: ["LaikaModel"])
    ]
)
