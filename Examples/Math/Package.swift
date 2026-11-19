// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Math",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "math", targets: ["Math"])
    ],
    dependencies: [
        .package(url: "https://github.com/julianschiavo/REPLico.git", from: "0.1.0")
    ],
    targets: [
        .executableTarget(
            name: "Math",
            dependencies: [.product(name: "ReplicoKit", package: "replico")]
        )
    ]
)
