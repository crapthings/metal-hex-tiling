// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "metal-hex-tiling",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MetalHexTiling", targets: ["MetalHexTiling"])
    ],
    targets: [
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
