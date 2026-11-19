#include <metal_stdlib>
#include "LightingShaderTypes.h"
using namespace metal;

// Stage 1 — video frame → light map.
//
// Input: the decoded frame from AVPlayerItemVideoOutput, wrapped as a texture through CVMetalTextureCache
// (BGRA, already scaled down by the video output; no CPU copy). Output: a 64 × 36 RGBA16F light map in linear light,
// alpha = the brightest luminance found inside the texel.
//
// Each light-map texel looks at a 4 × 4 grid of bilinear taps across its footprint. Bright taps weigh up to 7× more
// than dark ones, so a lamp, a flame or a neon tube keeps its own colour instead of being averaged into the dark
// around it ("preserve localized light sources"). Works for any input size: if the output were not scaled down,
// the taps simply skip pixels and the temporal smoothing downstream hides the aliasing.
kernel void cuven_sampleVideo(texture2d<float, access::sample> video [[texture(0)]],
                              texture2d<float, access::write> lightmap [[texture(1)]],
                              uint2 gid [[thread_position_in_grid]])
{
    const uint w = lightmap.get_width();
    const uint h = lightmap.get_height();
    if (gid.x >= w || gid.y >= h) { return; }

    constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
    const float2 cell = 1.0f / float2(float(w), float(h));
    const float2 origin = float2(gid) * cell;

    float3 sum = float3(0.0f);
    float weightSum = 0.0f;
    float peak = 0.0f;
    for (int j = 0; j < 4; ++j) {
        for (int i = 0; i < 4; ++i) {
            const float2 uv = origin + (float2(float(i), float(j)) + 0.5f) * 0.25f * cell;
            const float3 c = cuven::toLinear(saturate(video.sample(linearClamp, uv, level(0.0f)).rgb));
            const float l = cuven::luma(c);
            const float weight = 1.0f + 6.0f * smoothstep(0.2f, 0.85f, l);
            sum += c * weight;
            weightSum += weight;
            peak = max(peak, l);
        }
    }
    lightmap.write(float4(sum / weightSum, peak), gid);
}
