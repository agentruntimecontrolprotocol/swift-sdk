// swift-tools-version: 6.0
import PackageDescription

let sharedSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "ARCP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ARCP", targets: ["ARCP"]),
        .executable(name: "arcp", targets: ["arcp-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.74.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.15.0"),
        // Pin under 5.5.0: jwt-kit 5.5.x adds MLDSA support that requires
        // Swift 6.2+, but the test matrix exercises the declared floor of
        // swift-tools-version 6.0.
        .package(url: "https://github.com/vapor/jwt-kit.git", "5.1.0"..<"5.5.0"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.3"),
        .package(url: "https://github.com/apple/swift-format.git", from: "600.0.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "ARCP",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "WebSocketKit", package: "websocket-kit"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "SQLite", package: "SQLite.swift"),
            ],
            resources: [
                .copy("Store/Resources/schema.sql")
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .executableTarget(
            name: "arcp-cli",
            dependencies: [
                "ARCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/arcp-cli",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "ARCPTests",
            dependencies: [
                "ARCP",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "WebSocketKit", package: "websocket-kit"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
    ]
)
