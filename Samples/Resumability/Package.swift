// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Resumability",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "ARCP", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "Resumability",
            dependencies: [.product(name: "ARCP", package: "ARCP")],
            path: "Sources/Resumability"
        )
    ]
)
