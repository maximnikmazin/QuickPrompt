// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "QuickPrompt",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Renders the Markdown that models write (bold, headings, lists, tables) in the popup.
        .package(url: "https://github.com/gonzalezreal/textual", exact: "0.5.0")
    ],
    targets: [
        .executableTarget(
            name: "QuickPrompt",
            dependencies: [.product(name: "Textual", package: "textual")],
            path: "Sources/QuickPrompt",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
