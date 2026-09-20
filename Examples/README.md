# Terrain example

From the repository root:

```sh
swift run -c release HexTilingDemo
```

Requires macOS 13+, a Swift 6 toolchain with the macOS SDK, and a Metal-capable GPU. All runtime assets are bundled; no sibling repository or downloaded texture is required.

| Input | Action |
| --- | --- |
| Space | Toggle hex / ordinary repeat sampling |
| T | Toggle terrain / flat orthographic view |
| C | Toggle contrast correction (hex mode) |
| [ / ] | Decrease / increase patch scale (hex mode) |
| WASD / arrows | Move |
| Shift | Move faster |
| Drag / scroll | Look / adjust camera height in terrain view |
| F | Wireframe |
| R | Reset camera, preserving material settings |
| Command-Q | Quit |

The title reports active settings and whole-frame timings. These include terrain rendering and occasional height regeneration; they are not an isolated benchmark of the library.

## Read the integration

- `Terrain/TerrainRenderer.swift` loads the bundled sRGB texture with mipmaps, composes the library's MSL, and binds the 16-byte parameters.
- `Terrain/Resources/Terrain.metal` shows the sampling call and a repeat baseline with matching effective UV scale and gradients.
- `Terrain/main.swift` handles the MetalKit window and controls.
- `Terrain/FrameMonitor.swift` collects frame timings.

This example is adapted from the local `macos-metal-001` terrain viewer, including its generated moss/soil texture. The hexagonal mesh is an example-specific geometry choice; the library itself works with arbitrary geometry.

## GPU verification

```sh
swift run HexTilingDemo --verify
swift run HexTilingDemo --verify --top-down-flat
swift run HexTilingDemo --verify --plain-tiling --snapshot /tmp/repeat.png
```

Verification checks actual GPU output, repeatability, live sampling/view switches, camera movement, and continuity of the rolling height field. `--help` lists all options without requiring a GPU.

## Reproduce screenshots

From the repository root, use the current renderer to export the images used by the README and website:

```sh
swift run -c release HexTilingDemo --verify --plain-tiling --snapshot docs/images/terrain-repeat.png
swift run -c release HexTilingDemo --verify --snapshot docs/images/terrain-hex.png
swift run -c release HexTilingDemo --verify --top-down-flat --plain-tiling --snapshot docs/images/top-repeat.png
swift run -c release HexTilingDemo --verify --top-down-flat --snapshot docs/images/top-hex.png
```

These are raw renderer outputs with identical effective texture scale, not edited comparison composites. The old composite PNGs are retained as historical assets and are no longer referenced.

## Measure GPU frame time

```sh
swift run -c release HexTilingDemo --benchmark
swift run -c release HexTilingDemo --benchmark --top-down-flat
```

JSON output records hardware, OS, texture settings and mean/median/p95 GPU milliseconds for repeat, hex, and hex with contrast correction. Each mode has six rounds of 20 warmup frames and 50 timed frames (300 timed samples total). Mode order rotates each round; one command buffer is completed before the next is submitted.

This is a whole-frame comparison including geometry and lighting. Initial height generation, display presentation, CPU wait time, and image readback are excluded from the GPU timestamps. It is not a fullscreen sampling microbenchmark, a WebGL comparison, or a prediction of application FPS. Close other GPU-intensive apps and repeat measurements on target hardware before making performance claims.
