// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LaikaApp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LaikaAgentCore", targets: ["LaikaAgentCore"]),
        .executable(name: "laika-agent", targets: ["LaikaAgentCLI"]),
        .executable(name: "laika-server", targets: ["LaikaServer"])
    ],
    dependencies: [
        .package(path: "../shared"),
        .package(path: "../model")
    ],
    targets: [
        .target(
            name: "LaikaAgentCore",
            dependencies: [
                .product(name: "LaikaShared", package: "shared"),
                .product(name: "LaikaModel", package: "model")
            ]
        ),
        .executableTarget(
            name: "LaikaAgentCLI",
            dependencies: [
                "LaikaAgentCore",
                .product(name: "LaikaShared", package: "shared"),
                .product(name: "LaikaModel", package: "model")
            ]
        ),
        .executableTarget(
            name: "LaikaServer",
            dependencies: [
                "LaikaAgentCore",
                .product(name: "LaikaShared", package: "shared"),
                .product(name: "LaikaModel", package: "model")
            ]
        ),
        .testTarget(
            name: "LaikaAgentCoreTests",
            dependencies: ["LaikaAgentCore"]
        )
    ]
)
