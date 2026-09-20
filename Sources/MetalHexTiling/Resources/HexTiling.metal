#include <metal_stdlib>
using namespace metal;

#ifndef METAL_HEX_TILING_INCLUDED
#define METAL_HEX_TILING_INCLUDED

// x: patch scale, y: contrast correction (0/1), z: lookup threshold, w: weight exponent.
struct HexTilingArguments { float4 options; };

inline float2 hexTilingRandomOffset(float2 cell) {
    float2 h = float2(dot(cell, float2(127.1, 311.7)),
                      dot(cell, float2(269.5, 183.3)));
    return fract(sin(h) * 43758.5453);
}

inline float4 hexTilingLookup(texture2d<float> texture, sampler textureSampler,
                              float2 uv, float2 cell, float2 dx, float2 dy) {
    return texture.sample(textureSampler, uv - hexTilingRandomOffset(cell),
                          gradient2d(dx, dy));
}

/// Samples a seamless repeatable texture using Neyret-style stochastic hex tiling.
/// Input and output are linear. Use an sRGB texture format for color data and a linear
/// format for normal/roughness/metalness data.
inline float4 hexTilingSample(texture2d<float> texture, sampler textureSampler,
                              float2 uv, float2 uvDx, float2 uvDy,
                              constant HexTilingArguments &arguments) {
    float patchScale = max(arguments.options.x, 0.0001);
    // A single-level texture has no coarse mip that can approximate its mean.
    bool contrastCorrect = arguments.options.y >= 0.5 && texture.get_num_mip_levels() > 1;
    float threshold = clamp(arguments.options.z, 0.0, 1.0);
    float exponent = clamp(arguments.options.w, 0.0001, 64.0);

    float2 U = uv * patchScale * (exp2(1.8) / 8.0);
    float2 V = float2(U.x - U.y * 0.5773502691896258,
                      U.y * 1.1547005383792517);
    float2 I = floor(V);
    float2 sampleUV = U / patchScale;
    float2 sampleDx = uvDx * (exp2(1.8) / 8.0);
    float2 sampleDy = uvDy * (exp2(1.8) / 8.0);
    float4 mean = contrastCorrect
        ? texture.sample(textureSampler, sampleUV, level(99.0))
        : float4(0.0);

    float3 F = float3(fract(V), 0.0);
    F.z = 1.0 - F.x - F.y;
    float3 W;
    float2 cells[3];
    if (F.z > 0.0) {
        W = float3(F.z, F.y, F.x);
        cells[0] = I; cells[1] = I + float2(0, 1); cells[2] = I + float2(1, 0);
    } else {
        W = float3(-F.z, 1.0 - F.y, 1.0 - F.x);
        cells[0] = I + 1.0; cells[1] = I + float2(1, 0); cells[2] = I + float2(0, 1);
    }
    // Scaling before pow preserves normalized ratios and keeps the strongest
    // weight at one, even at the triangle centroid with exponent = 64.
    W = max(W, 0.0);
    W = pow(W / max(W.x, max(W.y, W.z)), exponent);
    W /= W.x + W.y + W.z;

    // Keep at least one sample even when threshold is 1. Renormalize after
    // skipping so constant inputs (including alpha/data maps) stay constant.
    uint strongest = W.y > W.x ? 1u : 0u;
    if (W.z > W[strongest]) strongest = 2u;
    for (uint index = 0; index < 3; ++index) {
        if (index != strongest && W[index] <= threshold) W[index] = 0.0;
    }
    W /= W.x + W.y + W.z;

    float4 result = 0.0;
    for (uint index = 0; index < 3; ++index) {
        if (W[index] > 0.0) {
            float4 value = hexTilingLookup(texture, textureSampler, sampleUV,
                                           cells[index], sampleDx, sampleDy);
            result.rgb += (value.rgb - mean.rgb) * W[index];
            result.a += value.a * W[index];
        }
    }
    if (contrastCorrect) result.rgb = mean.rgb + result.rgb / length(W);
    return result;
}

#endif
