// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickKit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QuickKit",
            path: "Sources/QuickKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
