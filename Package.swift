// swift-tools-version: 6.4
import CompilerPluginSupport
import PackageDescription

// BEGIN RUNTIME ARTIFACT
let runtimeTarget: Target = .binaryTarget(
    name: "ReplicoRuntimeArtifact",
    url: "https://github.com/julianschiavo/REPLico/releases/download/v0.2.0/ReplicoRuntime-0.2.0.artifactbundleindex",
    checksum: "802436014350d0688daa63c948b3b5d53e6ac0d053189d0626f817be7354ddcc"
)
// END RUNTIME ARTIFACT

let package = Package(
    name: "Replico",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ReplicoCore", targets: ["ReplicoCore"]),
        .library(name: "ReplicoMCP", targets: ["ReplicoMCP"]),
        .library(name: "ReplicoKit", targets: ["ReplicoKit", "ReplicoNode"]),
        .library(name: "ReplicoKitExternalNode", targets: ["ReplicoKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.105.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.9.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
    ],
    targets: [
        runtimeTarget,
        .target(
            name: "ReplicoCore",
            dependencies: [
                "ReplicoOptimizations", .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            resources: [.embedInCode("Resources/NodeWorker.bundle")]
        ),
        .target(
            name: "ReplicoMCP",
            dependencies: [
                "ReplicoCore", "ReplicoOptimizations", .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
        .target(
            name: "ReplicoOptimizations",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ]
        ),
        .macro(
            name: "ReplicoKitMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
        .target(name: "ReplicoKit", dependencies: ["ReplicoCore", "ReplicoMCP", "ReplicoKitMacros"]),
        .target(
            name: "ReplicoNode",
            dependencies: [
                "ReplicoKit", "ReplicoCore", "ReplicoRuntimeArtifact",
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .testTarget(name: "ReplicoCoreTests", dependencies: ["ReplicoCore"]),
        .testTarget(name: "ReplicoOptimizationsTests", dependencies: ["ReplicoOptimizations", "ReplicoCore"]),
        .testTarget(
            name: "ReplicoKitTests",
            dependencies: ["ReplicoKit", "ReplicoCore", "ReplicoNode", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(
            name: "ReplicoKitMacrosTests",
            dependencies: [
                "ReplicoKitMacros",
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "ReplicoMCPTests",
            dependencies: [
                "ReplicoCore", "ReplicoMCP",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
