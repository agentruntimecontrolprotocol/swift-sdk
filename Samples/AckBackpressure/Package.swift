// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AckBackpressure",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "ARCP", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "AckBackpressure",
            dependencies: [.product(name: "ARCP", package: "ARCP")],
            path: "Sources/AckBackpressure"
        )
    ]
)
