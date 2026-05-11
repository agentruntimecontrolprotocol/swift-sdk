// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LeaseRevocation",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "ARCP", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "LeaseRevocation",
            dependencies: [.product(name: "ARCP", package: "ARCP")],
            path: "Sources/LeaseRevocation"
        )
    ]
)
