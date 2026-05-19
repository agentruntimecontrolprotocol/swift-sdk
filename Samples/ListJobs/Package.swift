// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ListJobs",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "ARCP", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "ListJobs",
            dependencies: [.product(name: "ARCP", package: "ARCP")],
            path: "Sources/ListJobs"
        )
    ]
)
