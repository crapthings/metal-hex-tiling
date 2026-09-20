# Changelog

## Unreleased

- Add reproducible whole-frame GPU benchmarks and an initial Radeon Pro 580X baseline.
- Regenerate separate comparison screenshots with matched effective UV scale; render captions in HTML/Markdown so comparisons stack on narrow screens.

- Add the self-contained `HexTilingDemo` with bundled texture, live sampling/view controls, and offscreen GPU verification.
- Match the repeat baseline's effective UV scale to the library's source sampling scale.
- Stabilize high-exponent blend weights by scaling before exponentiation.
- Renormalize retained weights and always retain the strongest sample. Constant colors and alpha no longer darken when weak lookups are skipped.
- Apply contrast correction only to RGB; alpha remains a weighted blend.
- Disable contrast correction for textures with one mip level.
- Add real GPU sampling regression tests. GPU-less environments report explicit skips.

These changes intentionally adjust output from the initial port, especially with large exponents, high skip thresholds, transparency, or textures without mipmaps. No tagged release has been published yet.
