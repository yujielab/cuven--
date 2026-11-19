#include <metal_stdlib>
#include "LightingShaderTypes.h"
using namespace metal;

// Stage 5 — specular highlights (render, half resolution, additive).
//
// The up-to-four localized light sources found by cuven_selectLights sit on the folded screen. For each card pixel
// a normalised Blinn–Phong lobe is evaluated against each light: the half vector between the light direction and
// the eye, the bevelled card normal (so edges catch the light first), a glossiness that follows the light's size
// (a small lamp → a tight sparkle, a big bright window → a broad sheen), the light's emission toward the panel and
// inverse-square attenuation. Moving the eye (Core Motion) or the fold angle moves the highlights across the cards.
// Output is capped low and drawn at half resolution; the compositor upsamples it with a small tent filter.

fragment float4 cuven_specularFragment(cuven::SurfaceVaryings in [[stage_in]],
                                       constant CuvenFrameUniforms &u [[buffer(0)]],
                                       constant CuvenCardInstance *cards [[buffer(1)]],
                                       device const CuvenSceneState *scene [[buffer(2)]])
{
    const CuvenCardInstance c = cards[in.card];
    const float mixL = u.material.x * u.material.y;
    if (mixL <= 0.001f) { discard_fragment(); }

    const float2 ext = c.rect.zw * 0.5f;
    const float radius = min(c.shape.x, min(ext.x, ext.y));
    const float sd = cuven::roundedRectSDF(in.local, ext, radius);
    const float pxPerPt = u.viewport.z * 0.5f * (1.0f - 0.03f * c.shape.y);
    const float coverage = saturate(0.5f - sd * pxPerPt);
    if (coverage <= 0.0f) { discard_fragment(); }

    const cuven::Geometry g = cuven::geometry(u);
    const float2 edge = cuven::roundedRectNormal(in.local, ext, radius);
    const float3 N = cuven::bevelNormal(edge, sd, in.local, ext, 9.0f);
    const float3 P = cuven::panelToHinge(in.panelPoint, g);
    const float3 V = normalize(u.eye.xyz - P);
    const float3 ns = cuven::screenNormal(g);

    float3 sum = float3(0.0f);
    const uint count = min(uint(max(u.look2.w, 0.0f) + 0.5f), uint(CUVEN_MAX_LIGHTS));
    for (uint k = 0; k < count; ++k) {
        const CuvenLightSource source = scene->lights[k];
        const float presence = source.color.a;
        if (presence < 0.01f) { continue; }
        const float3 lightPoint = cuven::screenPoint(cuven::uvToPanel(source.position.xy, g), g);
        float3 toLight = lightPoint - P;
        const float dist2 = max(dot(toLight, toLight), 1.0f);
        toLight *= rsqrt(dist2);
        const float3 H = normalize(toLight + V);
        const float shininess = mix(260.0f, 36.0f, saturate(source.position.z * 4.0f));
        const float nh = saturate(dot(N, H));
        const float lobe = pow(nh, shininess) * (shininess + 8.0f) / (8.0f * M_PI_F);
        // Immersive: a second, much broader layer — the soft sheen around the sparkle
        const float wide = shininess * 0.12f;
        const float lobe2 = pow(nh, wide) * (wide + 8.0f) / (8.0f * M_PI_F) * 0.35f * u.look2.x;
        const float emission = saturate(dot(ns, -toLight) * 0.6f + 0.4f);
        const float attenuation = 1.0f / (1.0f + dist2 / (700.0f * 700.0f));
        sum += source.color.rgb * (source.position.w * presence * (lobe + lobe2) * emission * attenuation);
    }

    const bool lit = c.shape.w > 0.5f;
    // Specular strength of the preset; idle keeps the ambient light but quiets the highlights
    sum *= mixL * 0.10f * (0.6f + 0.8f * c.tint.y) * c.tint.x * (lit ? 0.3f : 1.0f) * u.look.y * (1.0f - 0.6f * u.look2.z);
    sum = cuven::softCap(sum, u.material.w * 0.5f);
    return float4(sum * coverage, 0.0f);
}
