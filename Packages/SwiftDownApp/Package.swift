// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SwiftDownApp",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../SwiftDownCore"),
        .package(path: "../SwiftDownPipeline"),
        .package(path: "../SwiftDownEditorKit")
    ],
    targets: [
        .executableTarget(
            name: "SwiftDown",
            dependencies: [
                .product(name: "SwiftDownCore", package: "SwiftDownCore"),
                .product(name: "SwiftDownPipeline", package: "SwiftDownPipeline"),
                .product(name: "SwiftDownEditorKit", package: "SwiftDownEditorKit")
            ]
        )
    ]
)
