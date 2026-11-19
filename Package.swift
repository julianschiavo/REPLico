// swift-tools-version: 6.4
import CompilerPluginSupport
import PackageDescription

// BEGIN RUNTIME ARTIFACT
let runtimeTarget: Target = .binaryTarget(
    name: "ReplicoRuntimeArtifact",
    url: "https://github.com/julianschiavo/REPLico/releases/download/v0.0.2/ReplicoRuntime-0.0.2.artifactbundleindex",
    checksum: "9a10a73a192d8a3d9c676f6133853dad4111593cf47b281620657b661ed12da8"
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
        .executable(name: "math", targets: ["Math"]),
        .executable(name: "math-complex", targets: ["MathComplex"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.105.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.9.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
    ],
    targets: [
        runtimeTarget,
        .plugin(
            name: "ReplicoResources",
            capability: .buildTool(),
            dependencies: ["ReplicoRuntimeArtifact"],
            exclude: ["StageResources.mjs"]
        ),
        .target(
            name: "ReplicoCore",
            dependencies: [
                "ReplicoOptimizations", .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            resources: [.copy("Resources/NodeWorker.bundle")]
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
        .target(name: "ReplicoNode", plugins: ["ReplicoResources"]),
        .executableTarget(
            name: "Math",
            dependencies: ["ReplicoKit", "ReplicoNode"],
            path: "Examples/Math",
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "MathComplex",
            dependencies: [
                "ReplicoKit", "ReplicoNode",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Examples/MathComplex",
            exclude: ["README.md"]
        ),
        .testTarget(name: "ReplicoCoreTests", dependencies: ["ReplicoCore"]),
        .testTarget(name: "ReplicoOptimizationsTests", dependencies: ["ReplicoOptimizations", "ReplicoCore"]),
        .testTarget(
            name: "ReplicoKitTests",
            dependencies: ["ReplicoKit", .product(name: "MCP", package: "swift-sdk")]
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
