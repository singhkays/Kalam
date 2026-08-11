// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KalamTextEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KalamTextEngine", targets: ["KalamTextEngine"]),
    ],
    targets: [
        .target(name: "KalamTextEngine"),
        .testTarget(name: "KalamTextEngineTests", dependencies: ["KalamTextEngine"]),
    ]
)
