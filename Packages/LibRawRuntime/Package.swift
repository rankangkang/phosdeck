// swift-tools-version: 5.9
import PackageDescription

// LibRaw 0.22.3 (LGPL-2.1, without GPL2/GPL3 demosaic packs, RawSpeed, Jasper, or LCMS).
let package = Package(
    name: "LibRawRuntime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LibRawRuntime", targets: ["LibRawRuntime"])
    ],
    targets: [
        .target(
            name: "CLibRaw",
            path: "Sources/CLibRaw",
            sources: ["src"],
            publicHeadersPath: "public",
            cxxSettings: [
                .headerSearchPath("."),
                .headerSearchPath("libraw"),
                .headerSearchPath("internal"),
                .define("USE_ZLIB", to: "1"),
                .unsafeFlags(["-w", "-O2"])
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("c++")
            ]
        ),
        .target(
            name: "CLibRawBridge",
            dependencies: ["CLibRaw"],
            path: "Sources/CLibRawBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../CLibRaw"),
                .unsafeFlags(["-w"])
            ]
        ),
        .target(
            name: "LibRawRuntime",
            dependencies: ["CLibRawBridge"],
            path: "Sources/LibRawRuntime"
        )
    ],
    cxxLanguageStandard: .cxx14
)
