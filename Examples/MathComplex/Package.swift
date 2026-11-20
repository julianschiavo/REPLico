// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MathComplex",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "math-complex", targets: ["MathComplex"])
    ],
    dependencies: [
        .package(url: "https://github.com/julianschiavo/REPLico.git", from: "0.2.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .executableTarget(
            name: "MathComplex",
            dependencies: [
                .product(name: "ReplicoKit", package: "replico"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        )
    ]
)
