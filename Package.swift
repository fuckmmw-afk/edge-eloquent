// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "EdgeEloquent",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "EdgeEloquent",
            targets: ["EdgeEloquentApp"]
        ),
        .library(
            name: "EdgeEloquent",
            targets: ["EdgeEloquent"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/google-ai-edge/LiteRT-LM.git",
            exact: "0.16.1"
        )
    ],
    targets: [
        .target(
            name: "EdgeEloquent",
            dependencies: [
                .product(name: "LiteRTLM", package: "LiteRT-LM")
            ],
            path: "Sources/EdgeEloquent"
        ),
        .executableTarget(
            name: "EdgeEloquentApp",
            dependencies: ["EdgeEloquent"],
            path: "Sources/EdgeEloquentApp"
        ),
        .testTarget(
            name: "EdgeEloquentTests",
            dependencies: ["EdgeEloquent"],
            path: "Tests/EdgeEloquentTests"
        ),
    ]
)
