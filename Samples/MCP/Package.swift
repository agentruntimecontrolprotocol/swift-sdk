// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MCP",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "ARCP", path: "../..")
        // No first-party Swift MCP SDK yet; stub the import.
        // TODO: replace with vendored bridge once `mcp-swift` stabilizes.
    ],
    targets: [
        .executableTarget(
            name: "MCP",
            dependencies: [.product(name: "ARCP", package: "ARCP")],
            path: "Sources/MCP"
        )
    ]
)
