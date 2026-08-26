// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "qmac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "qmac",
            path: "Sources/qmac",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
