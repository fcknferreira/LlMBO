// swift-tools-version:5.9
import PackageDescription

// Extensão de app: só APIs permitidas em extensões, e o processo começa no NSExtensionMain da Foundation
// (como o Xcode faz). Sem o `-e _NSExtensionMain`, o WidgetBundle.main() quebra com SIGTRAP.
let appExtension: [SwiftSetting] = [.unsafeFlags(["-application-extension"])]

let package = Package(
    name: "LlMBO",
    platforms: [.macOS(.v13)],
    targets: [
        // O que o app grava em widget.json e o widget lê.
        .target(name: "LlMBOWidgetModel", path: "Sources/WidgetModel", swiftSettings: appExtension),
        .executableTarget(name: "LlMBO", dependencies: ["LlMBOWidgetModel"], path: "Sources/LlMBO"),
        .executableTarget(
            name: "LlMBOWidget", dependencies: ["LlMBOWidgetModel"], path: "Sources/LlMBOWidget",
            swiftSettings: appExtension,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                                           "-Xlinker", "-application_extension"])]),
    ]
)
