// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "NoietsKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SharedModel", targets: ["SharedModel"]),
        .library(name: "VaultStore", targets: ["VaultStore"]),
        .library(name: "MarkdownKit", targets: ["MarkdownKit"]),
        .library(name: "VimKit", targets: ["VimKit"]),
        .library(name: "RenderKit", targets: ["RenderKit"]),
        .library(name: "IndexKit", targets: ["IndexKit"]),
        .library(name: "EditorKit", targets: ["EditorKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.0"),
    ],
    targets: [
        .target(name: "SharedModel"),
        .target(name: "VaultStore", dependencies: ["SharedModel"]),
        .target(name: "MarkdownKit", dependencies: ["SharedModel"]),
        .target(name: "VimKit", dependencies: ["SharedModel"]),
        .target(name: "RenderKit", dependencies: [
            "SharedModel",
            .product(name: "SwiftMath", package: "SwiftMath"),
        ]),
        .target(name: "IndexKit", dependencies: [
            "SharedModel", "VaultStore", "MarkdownKit",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "EditorKit", dependencies: ["SharedModel", "MarkdownKit", "VimKit", "RenderKit"]),
        .testTarget(name: "MarkdownKitTests", dependencies: ["MarkdownKit"]),
        .testTarget(name: "VimKitTests", dependencies: ["VimKit"]),
        .testTarget(name: "IndexKitTests", dependencies: ["IndexKit"]),
        .testTarget(name: "VaultStoreTests", dependencies: ["VaultStore"]),
    ]
)
