// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SwiftDownPipeline",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SwiftDownPipeline", targets: ["SwiftDownPipeline"])
    ],
    dependencies: [
        // 设计文档 §三：swift-markdown 首选；Ink 作为压测备选（协议隔离，可替换）
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "SwiftDownPipeline",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        .testTarget(name: "SwiftDownPipelineTests", dependencies: ["SwiftDownPipeline"])
    ]
)
