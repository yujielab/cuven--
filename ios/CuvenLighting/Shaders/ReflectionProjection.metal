#include <metal_stdlib>
#include "LightingShaderTypes.h"
using namespace metal;

// Stage 4 — projecting the picture's light onto the control surfaces.
//
// cuven_projectIrradiance (compute, quarter resolution of the panel)
//   The picture is treated as a grid of small area lights (32 × 18, or 16 × 9 when the device runs hot) sitting on
//   the screen half, which is folded up from the hinge at the current fold angle. For every quarter-resolution texel
//   of the panel we integrate what arrives from all of them:
//       E = Σ L · emit(θs) · cos θp / (d² + r0²) · ΔA / π
//   cos θp — the panel only receives light from above it; emit(θs) — a wide emission lobe of the screen (30 % floor:
//   real panels leak light at grazing angles, and it keeps the flat, unfolded layout lit a little). The squared
//   distance gives the attenuation: cards near the hinge glow more, a lamp at the left edge lights the left cards.
//   Multiple sources, their colour and their position all come out of the same sum — no averaged colour anywhere.
//
// cuven_surfaceVertex / cuven_surfaceFragment (render, full resolution) — the material of every control card:
//   dark translucent base with a soft sheen · diffuse light from the irradiance texture · a Fresnel-weighted mirror
//   reflection of the picture (the eye ray is reflected off a bevelled card normal and intersected with the folded
//   screen, then the blurred light map is sampled there; rougher with distance) · an edge light on the rim that faces
//   the screen · a soft luminance cap so the white SF Symbols drawn above always stay readable.

kernel void cuven_projectIrradiance(texture2d<float, access::sample> lightmap [[texture(0)]],
                                    texture2d<float, access::write> irradiance [[texture(1)]],
                                    constant CuvenFrameUniforms &u [[buffer(0)]],
                                    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= irradiance.get_width() || gid.y >= irradiance.get_height()) { return; }
    constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
    const cuven::Geometry g = cuven::geometry(u);
    const float2 p = (float2(gid) + 0.5f) / max(u.panel.z, 1e-3f);
    const float3 P = cuven::panelToHinge(p, g);
    const float3 ns = cuven::screenNormal(g);
    const int gx = max(int(u.analysis.y), 1);
    const int gy = max(int(u.analysis.z), 1);
    const float2 cellStep = 1.0f / float2(float(gx), float(gy));
    const float cellArea = g.videoRect.z * g.videoRect.w * cellStep.x * cellStep.y;

    float3 E = float3(0.0f);
    for (int j = 0; j < gy; ++j) {
        for (int i = 0; i < gx; ++i) {
            const float2 uv = (float2(float(i), float(j)) + 0.5f) * cellStep;
            const float3 L = lightmap.sample(linearClamp, uv, level(0.0f)).rgb;
            const float3 Q = cuven::screenPoint(cuven::uvToPanel(uv, g), g);
            const float3 D = P - Q;
            const float d2 = dot(D, D) + 900.0f;
            const float inv = rsqrt(d2);
            const float emit = 0.3f + 0.7f * saturate(dot(ns, D) * inv);
            const float receive = saturate((Q.z - P.z) * inv);
            E += L * (emit * receive / d2);
        }
    }
    irradiance.write(float4(E * (cellArea * u.analysis.w / M_PI_F), 1.0f), gid);
}

vertex cuven::SurfaceVaryings cuven_surfaceVertex(uint vid [[vertex_id]],
                                                  uint iid [[instance_id]],
                                                  constant CuvenFrameUniforms &u [[buffer(0)]],
                                                  constant CuvenCardInstance *cards [[buffer(1)]])
{
    const CuvenCardInstance c = cards[iid];
    const float2 corner = float2(float(vid & 1u), float((vid >> 1) & 1u));
    const float scale = 1.0f - 0.03f * c.shape.y;               // 0.97 when fully pressed
    const float2 center = c.rect.xy + c.rect.zw * 0.5f;
    const float2 ext = c.rect.zw * 0.5f * scale + 3.0f;          // margin for the rim and anti-aliasing
    const float2 p = center + (corner * 2.0f - 1.0f) * ext;
    const float2 px = p * u.viewport.z;

    cuven::SurfaceVaryings out;
    out.position = float4(px.x / u.viewport.x * 2.0f - 1.0f, 1.0f - px.y / u.viewport.y * 2.0f, 0.0f, 1.0f);
    out.local = (p - center) / scale;
    out.panelPoint = p;
    out.card = iid;
    return out;
}

fragment float4 cuven_surfaceFragment(cuven::SurfaceVaryings in [[stage_in]],
                                      constant CuvenFrameUniforms &u [[buffer(0)]],
                                      constant CuvenCardInstance *cards [[buffer(1)]],
                                      texture2d<float> irradiance [[texture(0)]],
                                      texture2d<float> nearMap [[texture(1)]],
                                      texture2d<float> farMap [[texture(2)]])
{
    constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
    const CuvenCardInstance c = cards[in.card];
    const float2 ext = c.rect.zw * 0.5f;
    const float radius = min(c.shape.x, min(ext.x, ext.y));
    const float sd = cuven::roundedRectSDF(in.local, ext, radius);
    const float pxPerPt = u.viewport.z * (1.0f - 0.03f * c.shape.y);
    const float coverage = saturate(0.5f - sd * pxPerPt);
    if (coverage <= 0.0f) { discard_fragment(); }

    const cuven::Geometry g = cuven::geometry(u);
    const float2 edge = cuven::roundedRectNormal(in.local, ext, radius);
    const float3 N = cuven::bevelNormal(edge, sd, in.local, ext, 9.0f);
    const float3 P = cuven::panelToHinge(in.panelPoint, g);
    const float3 V = normalize(u.eye.xyz - P);

    // Material: dark translucent surface, a touch lighter toward the upper middle like the reference cards
    const bool lit = c.shape.w > 0.5f;
    const float2 n = in.local / max(ext, float2(1.0f));
    const float sheen = 1.0f + 0.22f * saturate(1.0f - length(float2(n.x * 0.75f, n.y + 0.35f)));
    float3 base = lit ? float3(0.80f) : float3(0.0130f) * sheen;
    base += float3(lit ? -0.06f : 0.010f) * c.shape.y;      // pressed: a dark card lifts, a lit card dims

    const float mixL = u.material.x * u.material.y;
    float3 light = float3(0.0f);
    if (mixL > 0.001f) {
        // Diffuse light arriving from the picture
        const float2 irrSize = float2(float(irradiance.get_width()), float(irradiance.get_height()));
        const float3 E = irradiance.sample(linearClamp, in.panelPoint * u.panel.z / irrSize).rgb;
        const float3 diffuse = E * (0.42f + 0.18f * c.shape.z) * u.look.x;

        // Mirror reflection of the picture
        float3 reflection = float3(0.0f);
        const float3 R = reflect(-V, N);
        const float3 ns = cuven::screenNormal(g);
        const float denom = dot(ns, R);
        if (denom < -1e-3f) {
            const float t = dot(ns, float3(0.0f, 0.0f, g.spill) - P) / denom;
            if (t > 0.0f) {
                const float3 X = P + t * R;
                const float2 uv = cuven::panelToUV(cuven::screenHitToPanel(X, g), g);
                const float2 fadeIn = smoothstep(float2(-0.06f), float2(0.04f), uv);
                const float2 fadeOut = smoothstep(float2(-0.06f), float2(0.04f), float2(1.0f) - uv);
                const float inside = fadeIn.x * fadeIn.y * fadeOut.x * fadeOut.y;
                if (inside > 0.0f) {
                    const float gloss = c.tint.y;
                    const float3 sharp = nearMap.sample(linearClamp, saturate(uv)).rgb;
                    const float3 soft = farMap.sample(linearClamp, saturate(uv)).rgb;
                    const float cosV = saturate(dot(N, V));
                    const float fresnel = 0.06f + 0.94f * pow(1.0f - cosV, 5.0f);
                    // Reflection blur (Cinematic Reflection Mode) plus distance: far hits look rougher
                    const float rough = saturate(mix(t / 1400.0f, 1.0f, u.look.w) + (1.0f - gloss) * 0.3f);
                    reflection = mix(sharp, soft, rough) * fresnel * inside * u.material.z * (0.7f + 0.6f * c.shape.z)
                        * (1.0f - 0.35f * u.look2.z);
                }
            }
        }

        // Edge light: a thin band just inside the rim, strongest on the edge that faces the screen
        const float rim = smoothstep(-2.4f, -0.3f, sd) * (1.0f - smoothstep(-0.3f, 0.7f, sd));
        const float facing = saturate(dot(edge, -g.away) * 0.75f + 0.35f);
        // Fresnel-inspired: the bevel turns away from the eye, so the rim catches more at grazing angles
        const float edgeFresnel = 0.6f + 1.6f * pow(1.0f - saturate(dot(N, V)), 3.0f);
        const float3 rimLight = (E * 1.8f + reflection * 1.2f) * rim * facing * edgeFresnel * u.look.z;

        light = (diffuse + reflection + rimLight) * mixL;
    }

    // A faint static hairline so a card still reads in a black scene
    const float border = smoothstep(-1.4f, -0.2f, sd) * (1.0f - smoothstep(-0.2f, 0.6f, sd));
    float3 color;
    if (lit) {
        color = base + light * 0.35f;
    } else {
        color = cuven::softCap(base + light, u.material.w) + float3(0.022f) * border;
    }
    const float alpha = coverage * c.tint.x;
    return float4(color * alpha, alpha);
}

/// The black panel between the cards: a faint pool of the picture's light near the screen, fading away from it.
/// It follows the irradiance (colour and position), so it is never a uniform glow; drawn first, under the cards.
fragment float4 cuven_backdropFragment(cuven::ScreenVaryings in [[stage_in]],
                                       constant CuvenFrameUniforms &u [[buffer(0)]],
                                       texture2d<float> irradiance [[texture(0)]])
{
    constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
    const float level = u.look2.y * u.material.x * u.material.y;
    if (level <= 0.0005f) { discard_fragment(); }
    const float2 p = in.uv * u.panel.xy;
    const float2 irrSize = float2(float(irradiance.get_width()), float(irradiance.get_height()));
    const float3 E = irradiance.sample(linearClamp, p * u.panel.z / irrSize).rgb;
    const cuven::Geometry g = cuven::geometry(u);
    const float away = max(dot(p - g.hingePoint, g.away), 0.0f);
    const float falloff = exp(-away / max(u.panel.y * 0.45f, 1.0f));
    const float3 c = cuven::softCap(E * (level * 0.35f * falloff), u.material.w * 0.35f);
    return float4(c, 0.0f);
}
