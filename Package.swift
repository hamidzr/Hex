// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HexCLI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "hex-cli",
            targets: ["HexCLI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.15.0"),
    ],
    targets: [
        .executableTarget(
            name: "HexCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "HexCLI"
        ),
        .testTarget(
            name: "HexCLITests",
            dependencies: ["HexCLI"],
            path: "Tests"
        ),
    ]
) 