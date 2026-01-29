// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LaikaShared",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LaikaShared", targets: ["LaikaShared"])
    ],
    targets: [
        .target(
            name: "LaikaShared",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "LaikaSharedTests",
            dependencies: ["LaikaShared"],
            resources: [.process("Resources")]
        )
    ]
)
