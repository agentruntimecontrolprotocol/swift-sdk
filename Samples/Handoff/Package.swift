// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Handoff",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "ARCP", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "Handoff",
            dependencies: [.product(name: "ARCP", package: "ARCP")],
            path: "Sources/Handoff"
        )
    ]
)
