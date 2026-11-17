// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SwiftDownCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SwiftDownCore", targets: ["SwiftDownCore"])
    ],
    targets: [
        .target(name: "SwiftDownCore"),
        .testTarget(name: "SwiftDownCoreTests", dependencies: ["SwiftDownCore"])
    ]
)
