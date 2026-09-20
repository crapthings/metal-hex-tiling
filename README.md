# metal-hex-tiling

A small, Metal-only Swift package for stochastic, non-repeating texture tiling on Apple GPUs.

[Project page](https://crapthings.github.io/metal-hex-tiling/) · [Algorithm and architecture](Documentation/Architecture.md)

![Before and after comparison: regular repeat sampling versus stochastic hex tiling](docs/images/metal-hex-tiling-before-after.png)

The same seamless texture, terrain, camera, lighting, and UV scale—only the sampling method changes.

![Top-view comparison on flat terrain: regular repeat sampling versus stochastic hex tiling](docs/images/metal-hex-tiling-top-view-before-after.png)

The orthographic top view removes perspective, elevation, per-tile tint, and fog so the regular repetition grid—and its suppression by stochastic sampling—can be inspected directly.

## Why

Regular UV repetition preserves texture seams but exposes a visible grid of repeated features. MetalHexTiling samples the source texture at up to three deterministic random offsets and blends them over a triangular/hexagonal lattice. This breaks the repetition without generating geometry or storing a larger texture.

- Metal-only core; no MetalKit or AppKit dependency
- Explicit gradients for correct mip selection across patch boundaries
- Works with color, normal, roughness, and metalness maps
- Four runtime-tunable parameters in one 16-byte value

## Requirements

- macOS 13 or newer
- Swift 6 toolchain
- A Metal-capable GPU

The library depends on Metal, not MetalKit. It works with `MTKView`, `CAMetalLayer`, and offscreen renderers.

## Installation

Add this package to `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/crapthings/metal-hex-tiling.git",
        branch: "main"
    )
]
```

Then add `.product(name: "MetalHexTiling", package: "metal-hex-tiling")` to your target dependencies.

The package currently tracks `main`. A semantic-version dependency will be documented with the first tagged release.

## Usage

Compile the packaged MSL implementation together with your application shader:

```swift
import MetalHexTiling

let library = try HexTilingMetal.makeLibrary(
    device: device,
    appending: applicationShaderSource
)

var arguments = HexTilingParameters(patchScale: 2).shaderVector
encoder.setFragmentBytes(
    &arguments,
    length: MemoryLayout<SIMD4<Float>>.stride,
    index: 1
)
```

Then call the sampling primitive from the appended MSL source:

```metal
fragment float4 materialFragment(
    VertexOut in [[stage_in]],
    constant HexTilingArguments &hex [[buffer(1)]],
    texture2d<float> colorMap [[texture(0)]]) {
    constexpr sampler repeatingSampler(coord::normalized, address::repeat,
                                        filter::linear, mip_filter::linear);
    float2 uvDx = dfdx(in.uv);
    float2 uvDy = dfdy(in.uv);
    return hexTilingSample(colorMap, repeatingSampler, in.uv, uvDx, uvDy, hex);
}
```

Input textures must be seamless and should include mipmaps. Use an sRGB pixel format for color maps and linear formats for normal, roughness, and metalness maps. Blended normal maps still need decoding and normalization in your material pipeline.

## Parameters

| Parameter | Default | Meaning |
| --- | ---: | --- |
| `patchScale` | `2` | Higher values create smaller stochastic patches. |
| `useContrastCorrectedBlending` | `true` | Preserves more local contrast during blending. |
| `lookupSkipThreshold` | `0.01` | Skips low-weight texture reads to reduce bandwidth. |
| `textureSampleCoefficientExponent` | `8` | Controls blend sharpness and how often reads can be skipped. |

Each map costs up to three regular texture samples per fragment. Contrast correction adds one lookup at the coarsest mip level. See [Algorithm and architecture](Documentation/Architecture.md) for implementation details and performance tradeoffs.

## Development

```sh
swift test
```

The `macos-metal-001` sibling project is an executable integration example and runs an additional GPU render/readback verification.

## License and attribution

Distributed under the MIT License. This port derives from `three-hex-tiling`; see [NOTICE](NOTICE) for upstream attribution and the Shadertoy provenance noted by upstream.
