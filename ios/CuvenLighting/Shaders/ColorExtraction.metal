#include <metal_stdlib>
#include "LightingShaderTypes.h"
using namespace metal;

// Stage 3 — colour extraction: temporal smoothing and diffusion of the light map.
//
// cuven_temporalBlend   smoothed = mix(previous, current, k), k = 1 − e^(−dt/τ). τ is short (0.10 s) while the
//                       picture changes a little — a flame still flickers on the controls — and stretches to 0.38 s
//                       when cuven_analyzeScene reports a cut, so a new scene cross-fades in instead of popping.
// cuven_gaussianBlur    separable 9-tap Gaussian (run horizontally, then vertically). Two strengths:
//                       "near" (σ ≈ 1.5 texels) for directional reflections and the irradiance projection,
//                       "far" (σ ≈ 4.5 texels) for rough, soft ambient reflection.
// Ping-pong textures live in a pool on the Swift side; nothing is allocated per frame.

kernel void cuven_temporalBlend(texture2d<float, access::read> current [[texture(0)]],
                                texture2d<float, access::read> previous [[texture(1)]],
                                texture2d<float, access::write> output [[texture(2)]],
                                device const CuvenSceneState *scene [[buffer(1)]],
                                constant CuvenFrameUniforms &u [[buffer(2)]],
                                uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
    const float change = scene->stats.x;
    const float tau = mix(0.10f, 0.38f, change);
    const float k = 1.0f - exp(-max(u.analysis.x, 0.0f) / tau);
    output.write(mix(previous.read(gid), current.read(gid), k), gid);
}

kernel void cuven_gaussianBlur(texture2d<float, access::sample> source [[texture(0)]],
                               texture2d<float, access::write> output [[texture(1)]],
                               constant float4 &params [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]])
{
    // params.xy: blur direction (texels); params.z: sigma (texels)
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
    constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
    const float2 size = float2(float(output.get_width()), float(output.get_height()));
    const float2 uv = (float2(gid) + 0.5f) / size;
    const float sigma = max(params.z, 0.5f);
    const float spacing = max(1.0f, sigma * 0.5f);
    float4 sum = float4(0.0f);
    float weightSum = 0.0f;
    for (int i = -4; i <= 4; ++i) {
        const float x = float(i) * spacing;
        const float w = exp(-(x * x) / (2.0f * sigma * sigma));
        sum += source.sample(linearClamp, uv + params.xy * x / size, level(0.0f)) * w;
        weightSum += w;
    }
    output.write(sum / weightSum, gid);
}
