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
        .library(
            name: "EdgeEloquent",
            targets: ["EdgeEloquent"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "EdgeEloquent",
            dependencies: [],
            path: "Sources/EdgeEloquent"
        ),
        .testTarget(
            name: "EdgeEloquentTests",
            dependencies: ["EdgeEloquent"],
            path: "Tests/EdgeEloquentTests"
        ),
    ]
)
