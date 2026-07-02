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
    targets: [
        .target(name: "SharedModel"),
        .target(name: "VaultStore", dependencies: ["SharedModel"]),
        .target(name: "MarkdownKit", dependencies: ["SharedModel"]),
        .target(name: "VimKit", dependencies: ["SharedModel"]),
        .target(name: "RenderKit", dependencies: ["SharedModel"]),
        .target(name: "IndexKit", dependencies: ["SharedModel", "VaultStore", "MarkdownKit"]),
        .target(name: "EditorKit", dependencies: ["SharedModel", "MarkdownKit", "VimKit", "RenderKit"]),
        .testTarget(name: "MarkdownKitTests", dependencies: ["MarkdownKit"]),
        .testTarget(name: "VimKitTests", dependencies: ["VimKit"]),
    ]
)
