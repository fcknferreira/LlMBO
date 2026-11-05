// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LlMBO",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "LlMBO", path: "Sources/LlMBO")
    ]
)
