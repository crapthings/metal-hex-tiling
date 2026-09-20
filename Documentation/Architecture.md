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

## Color and data maps

The upstream GLSL applies approximate gamma conversion to the complete `vec4`, including data maps and alpha. This port instead blends sampled values linearly:

- use an sRGB Metal pixel format for base-color textures;
- use linear pixel formats for normal, roughness, and metalness textures;
- decode and renormalize blended normals in the host material pipeline.

This follows Metal/PBR resource semantics but is intentionally not pixel-identical to the WebGL implementation.

## Package boundary

The reusable target depends only on Metal. MetalKit owns optional host concerns such as `MTKView`, texture loading, and drawable timing, so it belongs in an application or example rather than the sampling library.

MSL is shipped as source and compiled together with the client shader. This lets Metal inline the sampling function and avoids a deployment dependency on Metal dynamic libraries.

## Performance

One map requires up to three filtered samples per fragment. Contrast correction adds a coarsest-mip lookup. A material using base color, normal, roughness, and metalness can therefore reach 16 lookups per fragment. Texture bandwidth is generally more important than the lattice/hash arithmetic.

Tune `lookupSkipThreshold` and `textureSampleCoefficientExponent` against representative content on the oldest supported GPU. A depth pre-pass can also help scenes with high overdraw.
