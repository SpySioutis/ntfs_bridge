// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NTFSBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NTFSBridgeCore", targets: ["NTFSBridgeCore"]),
        .executable(name: "NTFSBridgeApp", targets: ["NTFSBridgeApp"]),
    ],
    targets: [
        .target(name: "NTFSBridgeCore"),
        .executableTarget(
            name: "NTFSBridgeApp",
            dependencies: ["NTFSBridgeCore"]
        ),
        .testTarget(
            name: "NTFSBridgeCoreTests",
            dependencies: ["NTFSBridgeCore"]
        ),
    ]
)
