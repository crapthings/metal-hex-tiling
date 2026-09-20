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
    bool contrastCorrect = arguments.options.y >= 0.5;
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
    W = pow(max(W, 0.0), exponent);
    W /= max(W.x + W.y + W.z, 1e-8);

    float4 result = 0.0;
    for (uint index = 0; index < 3; ++index) {
        if (W[index] > threshold) {
            float4 value = hexTilingLookup(texture, textureSampler, sampleUV,
                                           cells[index], sampleDx, sampleDy);
            result += (value - mean) * W[index];
        }
    }
    return contrastCorrect ? mean + result / max(length(W), 1e-8) : result;
}

#endif
