// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PhosdeckPluginKit",
    platforms: [.macOS("26.0")],
    products: [.library(name: "PhosdeckPluginKit", type: .static, targets: ["PhosdeckPluginKit"])],
    targets: [
        .target(name: "PhosdeckPluginKit", dependencies: ["CPhosdeckPluginPixels"]),
        .target(name: "CPhosdeckPluginPixels")
    ],
    swiftLanguageModes: [.v5]
)
