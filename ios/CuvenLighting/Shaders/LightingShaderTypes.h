// CuvenLighting — data shared by the Metal shaders and the Swift engine.
//
// Every struct is made of 16-byte vectors only, so the Swift mirrors in LightingTypes.swift
// (SIMD4<Float> fields) have exactly the same size, alignment and field offsets.
// Coordinates:
//   · "panel space"  — points in the lighting surface view, origin top-left, y down.
//   · "hinge space"  — 3D points: x along the hinge, y away from the hinge toward the panel (toward the viewer),
//                      z up out of the panel. The panel is the plane z = 0. The video half of the screen rises from
//                      the hinge at the fold angle φ (180° = flat, 90° = upright like a laptop screen).

#ifndef CuvenLightingShaderTypes_h
#define CuvenLightingShaderTypes_h

#include <simd/simd.h>

#define CUVEN_LIGHTMAP_WIDTH 64
#define CUVEN_LIGHTMAP_HEIGHT 36
#define CUVEN_CELLS_X 16
#define CUVEN_CELLS_Y 9
#define CUVEN_CELL_COUNT 144
#define CUVEN_MAX_LIGHTS 4
#define CUVEN_MAX_CARDS 32

typedef struct {
    vector_float4 viewport;   // x, y: drawable size (px); z: px per pt; w: time (s)
    vector_float4 panel;      // x, y: panel size (pt); z: irradiance texels per pt; w: card count
    vector_float4 videoRect;  // displayed picture in panel space (pt): x, y, width, height
    vector_float4 hinge;      // x, y: a point on the hinge line (panel space, pt); z: fold angle (rad); w: spill height (pt)
    vector_float4 axes;       // xy: unit vector along the hinge; zw: unit vector from the hinge toward the panel
    vector_float4 eye;        // xyz: viewer position in hinge space (pt); w: unused
    vector_float4 material;   // x: intensity; y: lighting mix 0…1 (animated on/off); z: reflectivity; w: readability cap (linear luminance)
    vector_float4 analysis;   // x: dt since the previous lighting update (s); y, z: projection grid size; w: exposure
} CuvenFrameUniforms;

typedef struct {
    vector_float4 rect;       // panel space (pt): x, y, width, height
    vector_float4 shape;      // x: corner radius (pt); y: press amount 0…1; z: emphasis 0…1; w: lit (1 = white "on" surface)
    vector_float4 tint;       // x: surface opacity 0…1 (idle dimming); y: gloss 0…1; zw: unused
} CuvenCardInstance;

typedef struct {
    vector_float4 position;   // xy: picture uv; z: radius (uv); w: intensity (peak linear luminance)
    vector_float4 color;      // rgb: chroma (max component 1); a: presence weight 0…1 (0 = empty slot)
} CuvenLightSource;

typedef struct {
    vector_float4 average;    // rgb: average linear color; a: average luminance
    vector_float4 stats;      // x: scene change 0…1; y: peak luminance; z: bright coverage 0…1; w: analysed frame count
    CuvenLightSource lights[CUVEN_MAX_LIGHTS];
} CuvenSceneState;

typedef struct {
    vector_float4 color;      // rgb: average linear color of the cell; a: luminance
} CuvenCell;

#ifdef __METAL_VERSION__
#include <metal_stdlib>

namespace cuven {
using namespace metal;

/// What the surface vertex stage hands to the surface and specular fragment stages
struct SurfaceVaryings {
    float4 position [[position]];
    float2 local;              // pt, relative to the card centre (before the press scale)
    float2 panelPoint;         // pt, panel space
    uint card [[flat]];
};

inline float luma(float3 c) { return dot(c, float3(0.2126f, 0.7152f, 0.0722f)); }

/// Video (Rec. 709 / sRGB-like transfer) → linear light. Polynomial fit of the sRGB curve; plenty for lighting.
inline float3 toLinear(float3 c) { return c * (c * (c * 0.305306011f + 0.682171111f) + 0.012522878f); }

/// Linear → sRGB for the 8-bit drawable
inline float3 toSRGB(float3 c) {
    c = max(c, float3(0.0f));
    const float3 low = c * 12.92f;
    const float3 high = 1.055f * pow(c, float3(1.0f / 2.4f)) - 0.055f;
    return select(high, low, c <= float3(0.0031308f));
}

struct Geometry {
    float2 hingePoint;
    float2 along;
    float2 away;
    float fold;
    float spill;
    float4 videoRect;
};

inline Geometry geometry(constant CuvenFrameUniforms &u) {
    Geometry g;
    g.hingePoint = u.hinge.xy;
    g.along = u.axes.xy;
    g.away = u.axes.zw;
    g.fold = u.hinge.z;
    g.spill = u.hinge.w;
    g.videoRect = u.videoRect;
    return g;
}

/// A point of the panel (z = 0) in hinge space
inline float3 panelToHinge(float2 p, Geometry g) {
    const float2 d = p - g.hingePoint;
    return float3(dot(d, g.along), dot(d, g.away), 0.0f);
}

/// Direction in which the screen rises from the hinge
inline float3 screenUp(Geometry g) { return float3(0.0f, cos(g.fold), sin(g.fold)); }

/// Normal of the front of the screen (the side that faces the viewer and the panel)
inline float3 screenNormal(Geometry g) { return float3(0.0f, sin(g.fold), -cos(g.fold)); }

/// A point of the picture, given in panel-space layout coordinates, folded up onto the screen half
inline float3 screenPoint(float2 q, Geometry g) {
    const float2 d = q - g.hingePoint;
    const float s = dot(d, g.along);
    const float h = max(-dot(d, g.away), 0.0f);
    return float3(s, h * cos(g.fold), h * sin(g.fold) + g.spill);
}

inline float2 uvToPanel(float2 uv, Geometry g) { return g.videoRect.xy + uv * g.videoRect.zw; }
inline float2 panelToUV(float2 q, Geometry g) { return (q - g.videoRect.xy) / max(g.videoRect.zw, float2(1.0f)); }

/// A hit on the screen plane (hinge space) back to panel-space layout coordinates of the picture
inline float2 screenHitToPanel(float3 x, Geometry g) {
    const float h = dot(x - float3(0.0f, 0.0f, g.spill), screenUp(g));
    return g.hingePoint + x.x * g.along - h * g.away;
}

/// Signed distance to a rounded rectangle centred at the origin (negative inside)
inline float roundedRectSDF(float2 p, float2 ext, float r) {
    const float2 q = abs(p) - ext + r;
    return length(max(q, float2(0.0f))) + min(max(q.x, q.y), 0.0f) - r;
}

/// Outward 2D normal of the nearest edge of the rounded rectangle
inline float2 roundedRectNormal(float2 p, float2 ext, float r) {
    const float2 q = abs(p) - ext + r;
    float2 n;
    if (q.x > 0.0f && q.y > 0.0f) {
        n = normalize(q);
    } else {
        n = q.x > q.y ? float2(1.0f, 0.0f) : float2(0.0f, 1.0f);
    }
    const float2 s = select(float2(1.0f), float2(-1.0f), p < float2(0.0f));
    return n * s;
}

/// Surface normal of a card: flat in the middle, rolling over a soft bevel toward the edge,
/// with a very slight overall crown so a moving light glides across the face
inline float3 bevelNormal(float2 edgeNormal, float sd, float2 local, float2 ext, float bevel) {
    const float t = saturate(1.0f + sd / bevel);
    const float2 tilt = edgeNormal * (t * t) * 0.85f + (local / max(ext, float2(1.0f))) * 0.06f;
    return normalize(float3(tilt, 1.0f));
}

/// Soft cap on luminance: values stay untouched well below the cap and roll off smoothly into it,
/// so light never washes out the white symbols drawn on top
inline float3 softCap(float3 c, float cap) {
    const float l = luma(c);
    if (l <= 1e-5f || cap <= 0.0f) { return c; }
    const float knee = cap * 0.6f;
    if (l <= knee) { return c; }
    const float over = (l - knee) / (cap - knee);
    const float mapped = knee + (cap - knee) * (over / (1.0f + over));
    return c * (mapped / l);
}

} // namespace cuven
#endif

#endif
