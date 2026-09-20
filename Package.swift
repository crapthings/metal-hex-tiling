// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "metal-hex-tiling",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MetalHexTiling", targets: ["MetalHexTiling"]),
        .executable(name: "HexTilingDemo", targets: ["HexTilingDemo"])
    ],
    targets: [
        .executableTarget(
            name: "HexTilingDemo",
            dependencies: ["MetalHexTiling"],
            path: "Examples/Terrain",
            resources: [.copy("Resources/Terrain.metal"), .copy("Resources/ground-moss-seamless.png")],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("MetalKit")]
        ),
        .target(
            name: "MetalHexTiling",
            resources: [.copy("Resources/HexTiling.metal")],
            linkerSettings: [.linkedFramework("Metal")]
        ),
        .testTarget(
            name: "MetalHexTilingTests",
            dependencies: ["MetalHexTiling"]
        )
    ],
    swiftLanguageModes: [.v5]
)
