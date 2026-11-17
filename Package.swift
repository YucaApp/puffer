// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Puffer",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: data model, JSON storage, shortcode matching. No AppKit.
        .target(
            name: "PufferCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu bar app: event tap, text injection, editor window.
        .executableTarget(
            name: "Puffer",
            dependencies: ["PufferCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PufferCoreTests",
            dependencies: ["PufferCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PufferTests",
            dependencies: ["Puffer", "PufferCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
