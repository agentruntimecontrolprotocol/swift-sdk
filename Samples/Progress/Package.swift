// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Progress",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "ARCP", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "Progress",
            dependencies: [.product(name: "ARCP", package: "ARCP")],
            path: "Sources/Progress"
        )
    ]
)
