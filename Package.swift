// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskWarden",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DiskWarden",
            path: "Sources/DiskWarden",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
