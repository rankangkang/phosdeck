// swift-tools-version: 5.9
import PackageDescription

// Official Google LiteRT 2.3.0 macOS runtime; no training/conversion toolchain.
let package = Package(
    name: "SmartMaskRuntime",
    platforms: [.macOS(.v12)],
    products: [.library(name: "SmartMaskRuntime", targets: ["CLiteRT_mac"])],
    targets: [.binaryTarget(name: "CLiteRT_mac",
        url: "https://github.com/google-ai-edge/LiteRT/releases/download/v2.3.0/CLiteRT_mac.xcframework.zip",
        checksum: "071b9f4bebb483709ac3d7faf98123da5453a2ebf60ce8f819aa1e30b9535a98")]
)
