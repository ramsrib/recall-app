// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RecallApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "RecallApp",
            path: "Sources/RecallApp"
        )
    ]
)
