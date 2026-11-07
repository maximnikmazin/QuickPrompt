// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "QuickPrompt",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "QuickPrompt",
            path: "Sources/QuickPrompt",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
