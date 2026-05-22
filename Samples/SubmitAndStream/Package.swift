// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SubmitAndStream",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "ARCP", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "SubmitAndStream",
            dependencies: [.product(name: "ARCP", package: "ARCP")],
            path: "Sources/SubmitAndStream"
        )
    ]
)
