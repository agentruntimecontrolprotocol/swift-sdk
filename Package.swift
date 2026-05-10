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
        .executable(name: "sample-01-minimal-session", targets: ["Sample01MinimalSession"]),
        .executable(name: "sample-02-tool-invoke-progress", targets: ["Sample02ToolInvokeProgress"]),
        .executable(name: "sample-03-human-input-request", targets: ["Sample03HumanInputRequest"]),
        .executable(name: "sample-04-permission-challenge", targets: ["Sample04PermissionChallenge"]),
        .executable(name: "sample-05-observer-subscription", targets: ["Sample05ObserverSubscription"]),
        .executable(
            name: "sample-06-relay-human-in-the-loop",
            targets: ["Sample06RelayHumanInTheLoop"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.74.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.15.0"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.1.0"),
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
        .executableTarget(
            name: "Sample01MinimalSession",
            dependencies: ["ARCP"],
            path: "Samples/01-MinimalSession",
            swiftSettings: sharedSwiftSettings
        ),
        .executableTarget(
            name: "Sample02ToolInvokeProgress",
            dependencies: ["ARCP"],
            path: "Samples/02-ToolInvokeWithProgress",
            swiftSettings: sharedSwiftSettings
        ),
        .executableTarget(
            name: "Sample03HumanInputRequest",
            dependencies: ["ARCP"],
            path: "Samples/03-HumanInputRequest",
            swiftSettings: sharedSwiftSettings
        ),
        .executableTarget(
            name: "Sample04PermissionChallenge",
            dependencies: ["ARCP"],
            path: "Samples/04-PermissionChallenge",
            swiftSettings: sharedSwiftSettings
        ),
        .executableTarget(
            name: "Sample05ObserverSubscription",
            dependencies: ["ARCP"],
            path: "Samples/05-ObserverSubscription",
            swiftSettings: sharedSwiftSettings
        ),
        .executableTarget(
            name: "Sample06RelayHumanInTheLoop",
            dependencies: ["ARCP"],
            path: "Samples/06-RelayHumanInTheLoop",
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
