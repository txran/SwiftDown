// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SwiftDownEditorKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SwiftDownEditorKit", targets: ["SwiftDownEditorKit"])
    ],
    targets: [
        .target(name: "SwiftDownEditorKit"),
        .testTarget(name: "SwiftDownEditorKitTests", dependencies: ["SwiftDownEditorKit"])
    ]
)
