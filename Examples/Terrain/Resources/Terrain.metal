#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProjection;
    float4 camera;           // xyz, unused
    float4 patch;            // texture world origin xz, world size, height scale
    int4 grid;              // first column, first row, side length, unused
};

uint hashBits(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    return x ^ (x >> 16);
}
float randomAt(int2 p, uint seed = 0) {
    return float(hashBits(uint(p.x) * 0x9e3779b9u ^ uint(p.y) * 0x85ebca6bu ^ seed) & 0xffffffu) / 16777215.0;
}
float noise(float2 p) {
    int2 cell = int2(floor(p));
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(randomAt(cell), randomAt(cell + int2(1, 0)), f.x),
               mix(randomAt(cell + int2(0, 1)), randomAt(cell + int2(1, 1)), f.x), f.y);
}
float fbm(float2 p) {
    float sum = 0.0, amplitude = 0.5;
    for (int octave = 0; octave < 6; ++octave) {
        sum += amplitude * noise(p);
        p = p * 2.03 + float2(17.7, 9.2);
        amplitude *= 0.5;
    }
    return sum / 0.984375;
}

// A moving world-space window, not a repeating 512-pixel tile.
kernel void generateHeight(texture2d<float, access::write> height [[texture(0)]],
                           constant Uniforms &u [[buffer(0)]], uint2 id [[thread_position_in_grid]]) {
    if (any(id >= uint2(height.get_width(), height.get_height()))) return;
    float2 world = u.patch.xy + (float2(id) + 0.5) * (u.patch.z / 512.0);
    float2 p = world * 0.008;
    float2 warp = float2(noise(p * 0.7 + 31.2), noise(p * 0.7 - 19.8)) - 0.5;
    float h = fbm(p + warp * 1.6);
    height.write(float4(h), id);
}

constexpr sampler heightSampler(coord::normalized, address::clamp_to_edge, filter::linear);
float elevation(float2 world, texture2d<float> height, constant Uniforms &u) {
    return height.sample(heightSampler, (world - u.patch.xy) / u.patch.z, level(0)).r * u.patch.w;
}

struct VertexOut {
    float4 position [[position]];
    float3 world;
    float tint [[flat]];
};

vertex VertexOut terrainVertex(uint vertexID [[vertex_id]], uint instance [[instance_id]],
                               constant Uniforms &u [[buffer(0)]], texture2d<float> height [[texture(0)]]) {
    int row = u.grid.y + int(instance) / u.grid.z;
    int col = u.grid.x + int(instance) % u.grid.z;
    int2 center = int2(2 * col + (row & 1), 3 * row);
    const int2 corners[] = {int2(1,1), int2(0,2), int2(-1,1), int2(-1,-1), int2(0,-2), int2(1,-1)};
    uint triangle = vertexID / 3;
    uint corner = vertexID % 3;
    int2 lattice = center;
    if (corner != 0) lattice += corners[(triangle + corner - 1) % 6];
    // Shared lattice vertices receive identical perturbations across adjacent hexes.
    float2 world = float2(lattice) * float2(1.7320508075688772, 1.0);
    world += (float2(randomAt(lattice, 123u), randomAt(lattice, 456u)) - 0.5) * 0.65;
    bool flatTerrain = (u.grid.w & 2) != 0;
    float3 position = float3(world.x, flatTerrain ? 0.0 : elevation(world, height, u), world.y);
    VertexOut out;
    out.position = u.viewProjection * float4(position, 1.0);
    out.world = position;
    out.tint = randomAt(int2(col, row), 789u);
    return out;
}

fragment float4 terrainFragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                constant HexTilingArguments &hex [[buffer(1)]],
                                texture2d<float> material [[texture(0)]]) {
    float3 normal = normalize(cross(dfdx(in.world), dfdy(in.world)));
    if (normal.y < 0.0) normal = -normal;
    float height = in.world.y / u.patch.w;
    float3 low = float3(0.16, 0.27, 0.19);
    float3 grass = float3(0.37, 0.47, 0.25);
    float3 rock = float3(0.55, 0.52, 0.43);
    constexpr sampler materialSampler(coord::normalized, address::repeat, filter::linear,
                                      mip_filter::linear, max_anisotropy(8));
    // One source tile spans roughly 16.7 world units. Hex tiling randomizes three
    // translated samples per patch and explicit gradients preserve mip selection.
    float2 uv = in.world.xz * 0.06;
    float2 uvDx = dfdx(uv);
    float2 uvDy = dfdy(uv);
    float4 tiled;
    if ((u.grid.w & 1) != 0) {
        tiled = hexTilingSample(material, materialSampler, uv, uvDx, uvDy, hex);
    } else {
        // Match the effective source scale used inside hexTilingSample.
        const float sourceScale = exp2(1.8) / 8.0;
        tiled = material.sample(materialSampler, uv * sourceScale,
                                gradient2d(uvDx * sourceScale, uvDy * sourceScale));
    }
    float3 terrainTint = mix(low, grass, smoothstep(0.25, 0.58, height));
    float luminance = dot(tiled.rgb, float3(0.2126, 0.7152, 0.0722));
    float3 color = tiled.rgb * mix(float3(0.72, 0.82, 0.67), terrainTint * 2.0,
                                   smoothstep(0.15, 0.75, luminance));
    color = mix(color, rock, max(smoothstep(0.60, 0.79, height), 1.0 - smoothstep(0.65, 0.93, normal.y)));
    bool flatTerrain = (u.grid.w & 2) != 0;
    if (!flatTerrain) color *= 0.87 + in.tint * 0.26;
    float light = 0.42 + 0.68 * max(dot(normal, normalize(float3(-0.5, 0.8, 0.3))), 0.0);
    color *= light;
    float distance = length(in.world.xz - u.camera.xz);
    float fog = flatTerrain ? 0.0 : smoothstep(100.0, 195.0, distance);
    return float4(mix(color, float3(0.59, 0.70, 0.76), fog), 1.0);
}
