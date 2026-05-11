// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Subscriptions",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "ARCP", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "Subscriptions",
            dependencies: [.product(name: "ARCP", package: "ARCP")],
            path: "Sources/Subscriptions"
        )
    ]
)
