#include <metal_stdlib>
#include "LightingShaderTypes.h"
using namespace metal;

// Stage 6 — final composite into the drawable (full resolution).
//
// surface (full-resolution RGBA16F, premultiplied, black where there is no card)
// + specular highlights (half-resolution RGBA16F, upsampled with a 5-tap tent so they stay soft)
// → linear-to-sRGB encode for the 8-bit drawable, with ±½ LSB interleaved-gradient-noise dither so the dark
// gradients of the cards do not band. The background stays pure black.

vertex cuven::ScreenVaryings cuven_compositeVertex(uint vid [[vertex_id]])
{
    // One triangle that covers the whole target: (−1,−1), (3,−1), (−1,3)
    const float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));
    cuven::ScreenVaryings out;
    out.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    out.uv = float2(p.x, 1.0f - p.y);
    return out;
}

fragment float4 cuven_compositeFragment(cuven::ScreenVaryings in [[stage_in]],
                                        texture2d<float> surface [[texture(0)]],
                                        texture2d<float> specular [[texture(1)]])
{
    constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
    const uint2 pixel = uint2(in.position.xy);
    const float4 s = surface.read(min(pixel, uint2(surface.get_width() - 1, surface.get_height() - 1)));

    const float2 texel = 1.0f / float2(float(specular.get_width()), float(specular.get_height()));
    float3 highlight = specular.sample(linearClamp, in.uv).rgb * 0.4f;
    highlight += specular.sample(linearClamp, in.uv + float2(texel.x, 0.0f)).rgb * 0.15f;
    highlight += specular.sample(linearClamp, in.uv - float2(texel.x, 0.0f)).rgb * 0.15f;
    highlight += specular.sample(linearClamp, in.uv + float2(0.0f, texel.y)).rgb * 0.15f;
    highlight += specular.sample(linearClamp, in.uv - float2(0.0f, texel.y)).rgb * 0.15f;

    const float3 color = s.rgb + highlight;
    const float noise = fract(52.9829189f * fract(dot(in.position.xy, float2(0.06711056f, 0.00583715f)))) - 0.5f;
    const float3 encoded = cuven::toSRGB(color) + noise / 255.0f;
    return float4(saturate(encoded), 1.0f);
}
