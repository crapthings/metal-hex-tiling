# Algorithm and architecture

## What “hex tiling” means

This package does not generate hexagonal geometry. It maps UV space onto an equilateral triangular lattice. Each lattice vertex selects a deterministic random translation of the same repeatable texture. A fragment blends the three translations belonging to its containing triangle using barycentric weights. Adjacent triangles share lattice vertices and offsets, keeping the result continuous. Groups of six triangles form the hexagonal patches behind the name.

## Sampling sequence

1. Scale UV by `patchScale` and the upstream compatibility constant `exp2(1.8) / 8`.
2. Transform into the triangular lattice basis.
3. Select one of the two triangles in the current lattice parallelogram.
4. Compute and exponentiate three barycentric weights.
5. Hash each lattice vertex into a deterministic `[0, 1)` texture translation.
6. Skip samples whose normalized weight is below the configured threshold.
7. Blend the remaining samples, optionally using contrast correction.

The algorithm breaks visual periodicity; it does not make a non-seamless source texture seamless.

## Explicit gradients

Random UV translations are discontinuous across patch boundaries. Implicit derivatives would interpret these jumps as extreme minification and choose incorrect mip levels. The API therefore requires derivatives calculated from the original continuous UV and uses `gradient2d` for every translated lookup.

Calculate `dfdx` and `dfdy` before entering non-uniform control flow.

## Stable weights and skipped samples

Weights are divided by their maximum before exponentiation, then normalized. This preserves their ratios while avoiding underflow near triangle centers at large exponents. After the skip threshold is applied, the surviving weights are normalized again; the strongest sample is retained even when the threshold is one. Constant input therefore stays constant. Nonzero skip thresholds still introduce small discontinuities when samples cross the threshold; use zero when inspecting continuity.

## Color and data maps

The upstream GLSL applies approximate gamma conversion to the complete `vec4`, including data maps and alpha. This port instead blends sampled values linearly:

- use an sRGB Metal pixel format for base-color textures;
- use linear pixel formats for normal, roughness, and metalness textures;
- decode and renormalize blended normals in the host material pipeline.

This follows Metal/PBR resource semantics but is intentionally not pixel-identical to the WebGL implementation.

Contrast correction applies only to RGB. Alpha always uses normalized weighted blending. Disable correction for data maps by default, decode normal RGB from `[0,1]` to `[-1,1]`, then normalize before transforming through your tangent basis. The flat-normal GPU test verifies neutral data preservation, not a complete tangent-space lighting implementation.

Correction estimates the mean from the coarsest mip and is automatically disabled for single-level textures. Provide a complete, correctly generated mip chain for a meaningful global mean. RGB output may exceed `[0,1]`; downstream code owns tone mapping or clamping bounded material values.

## Package boundary

The reusable target depends only on Metal. MetalKit owns optional host concerns such as `MTKView`, texture loading, and drawable timing, so it belongs in an application or example rather than the sampling library.

MSL is shipped as source and compiled together with the client shader. This lets Metal inline the sampling function and avoids a deployment dependency on Metal dynamic libraries.

## Performance

One map requires up to three filtered samples per fragment. Contrast correction adds a coarsest-mip lookup. A material using base color, normal, roughness, and metalness can therefore reach 16 lookups per fragment. Texture bandwidth is generally more important than the lattice/hash arithmetic.

Tune `lookupSkipThreshold` and `textureSampleCoefficientExponent` against representative content on the oldest supported GPU. A depth pre-pass can also help scenes with high overdraw.
