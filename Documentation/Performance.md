# Performance measurements

Measured locally on 2026-09-20 using the release build of `HexTilingDemo` after the stable-weight/alpha fixes. This is an initial single-machine baseline, not a claim about all Metal devices or performance relative to the original Three.js library.

## Configuration

- AMD Radeon Pro 580X, 8 GB; macOS 15.7.9 (24G830).
- 1280 × 720 offscreen sRGB render target, 145 × 145 terrain instances.
- One 1254 × 1254 sRGB color texture, 11 mip levels, linear/mip-linear filtering, maximum anisotropy 8.
- Patch scale 3, exponent 8, skip threshold 0.01; identical effective source UV scale for all modes.
- Six rotating rounds per mode, each with 20 warmup frames and 50 timed frames; 300 recorded frames per mode.
- GPU command-buffer timestamps, serial completion. No display presentation or readback. Height generation occurs before measurement.

## Results

All values are GPU milliseconds for the entire offscreen frame, including geometry and shading.

| View | Sampling | Mean | Median | p95 |
| --- | --- | ---: | ---: | ---: |
| Terrain | Repeat | 0.3311 | 0.3232 | 0.3827 |
| Terrain | Hex, correction off | 0.4192 | 0.4123 | 0.4626 |
| Terrain | Hex, correction on | 0.4446 | 0.4360 | 0.4931 |
| Flat top view | Repeat | 0.2736 | 0.2682 | 0.2994 |
| Flat top view | Hex, correction off | 0.3809 | 0.3752 | 0.4011 |
| Flat top view | Hex, correction on | 0.3909 | 0.3874 | 0.4077 |

For this workload, enabling hex sampling with correction adds approximately 0.113 ms to the terrain median and 0.119 ms to the top-view median. These differences are not isolated instruction costs: pipeline scheduling, caches and scene shading interact. Serial GPU timing also does not predict displayed FPS or sustained throughput with multiple frames in flight.

Apple Silicon measurements, multi-map materials, a sampling-only fullscreen benchmark, and repeated-run variability have not yet been established. GPU clocks, thermal state and competing workloads can affect results.

## Reproduce

```sh
swift run -c release HexTilingDemo --benchmark
swift run -c release HexTilingDemo --benchmark --top-down-flat
```

Each command prints JSON including hardware, settings, sample count and timing statistics. Run without other GPU-heavy applications. When reporting numbers, include this metadata and identify any shader changes.
