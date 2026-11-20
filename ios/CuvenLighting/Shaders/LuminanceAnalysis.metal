#include <metal_stdlib>
#include "LightingShaderTypes.h"
using namespace metal;

// Stage 2 — luminance analysis. Two single-threadgroup kernels (16 × 9 = 144 threads, one per cell of the picture):
//
// cuven_analyzeScene   reads the raw light map of this frame:
//   · per-cell average colour and luminance (cells[0…143], also read back for the sampled-colour visualisation);
//   · how much the picture changed since the previous analysed frame (cells[144…287] keep the previous frame),
//     condensed into one "scene change" value 0…1 that the temporal smoothing uses to cross-fade scene cuts;
//   · average colour, peak luminance and bright coverage of the whole frame.
//
// cuven_selectLights   reads the temporally smoothed light map and finds up to four localized light sources:
//   score = brightness × how much it stands out, picked greedily with non-maximum suppression, refined to the
//   weighted centroid of the 3 × 3 neighbourhood. The four slots are tracked over time (matched to the nearest
//   previous light, eased toward it, faded in and out), so specular highlights glide instead of jumping.
// Nothing comes back to the CPU for rendering: the light list stays in a GPU buffer the highlight pass reads.

kernel void cuven_analyzeScene(texture2d<float, access::read> lightmap [[texture(0)]],
                               device CuvenCell *cells [[buffer(0)]],
                               device CuvenSceneState *scene [[buffer(1)]],
                               uint2 tid [[thread_position_in_threadgroup]],
                               uint index [[thread_index_in_threadgroup]])
{
    threadgroup float tgDiff[CUVEN_CELL_COUNT];
    threadgroup float tgPeak[CUVEN_CELL_COUNT];
    threadgroup float4 tgColor[CUVEN_CELL_COUNT];

    const uint cw = max(lightmap.get_width() / uint(CUVEN_CELLS_X), 1u);
    const uint ch = max(lightmap.get_height() / uint(CUVEN_CELLS_Y), 1u);
    float3 sum = float3(0.0f);
    float peak = 0.0f;
    for (uint y = 0; y < ch; ++y) {
        for (uint x = 0; x < cw; ++x) {
            const float4 t = lightmap.read(uint2(tid.x * cw + x, tid.y * ch + y));
            sum += t.rgb;
            peak = max(peak, t.a);
        }
    }
    const float3 avg = sum / float(cw * ch);
    const float l = cuven::luma(avg);
    const float4 previous = cells[CUVEN_CELL_COUNT + index].color;
    // Compare in a square-root space so a cut between two dark shots still registers
    const float diff = length(sqrt(max(avg, float3(0.0f))) - sqrt(max(previous.rgb, float3(0.0f))));

    tgDiff[index] = diff;
    tgPeak[index] = peak;
    tgColor[index] = float4(avg, l);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (index == 0) {
        float diffSum = 0.0f;
        float lumaSum = 0.0f;
        float maxPeak = 0.0f;
        float bright = 0.0f;
        float3 colorSum = float3(0.0f);
        for (uint i = 0; i < CUVEN_CELL_COUNT; ++i) {
            diffSum += tgDiff[i];
            lumaSum += tgColor[i].a;
            colorSum += tgColor[i].rgb;
            maxPeak = max(maxPeak, tgPeak[i]);
            bright += tgPeak[i] > 0.55f ? 1.0f : 0.0f;
        }
        const float n = float(CUVEN_CELL_COUNT);
        const float frames = scene->stats.w;
        const float change = frames < 0.5f ? 1.0f : smoothstep(0.04f, 0.22f, diffSum / n);
        scene->average = float4(colorSum / n, lumaSum / n);
        scene->stats = float4(change, maxPeak, bright / n, frames + 1.0f);
    }

    cells[index].color = float4(avg, l);
    cells[CUVEN_CELL_COUNT + index].color = float4(avg, l);
}

static float2 cellCenterUV(uint x, uint y) {
    return (float2(float(x), float(y)) + 0.5f) / float2(float(CUVEN_CELLS_X), float(CUVEN_CELLS_Y));
}

kernel void cuven_selectLights(texture2d<float, access::read> smoothed [[texture(0)]],
                               device CuvenSceneState *scene [[buffer(1)]],
                               constant CuvenFrameUniforms &u [[buffer(2)]],
                               uint2 tid [[thread_position_in_threadgroup]],
                               uint index [[thread_index_in_threadgroup]])
{
    threadgroup float tgScore[CUVEN_CELL_COUNT];
    threadgroup float4 tgColor[CUVEN_CELL_COUNT];

    const uint cw = max(smoothed.get_width() / uint(CUVEN_CELLS_X), 1u);
    const uint ch = max(smoothed.get_height() / uint(CUVEN_CELLS_Y), 1u);
    float3 sum = float3(0.0f);
    float peak = 0.0f;
    for (uint y = 0; y < ch; ++y) {
        for (uint x = 0; x < cw; ++x) {
            const float4 t = smoothed.read(uint2(tid.x * cw + x, tid.y * ch + y));
            sum += t.rgb;
            peak = max(peak, t.a);
        }
    }
    const float3 avg = sum / float(cw * ch);
    const float l = cuven::luma(avg);
    // A light source is bright AND brighter than the frame around it
    const float standout = saturate((peak - scene->average.a * 1.4f) * 2.5f);
    tgScore[index] = smoothstep(0.06f, 0.5f, peak) * (0.3f + l) * (0.25f + standout);
    tgColor[index] = float4(avg, peak);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (index != 0) { return; }

    // Pick up to four candidates with non-maximum suppression
    CuvenLightSource candidates[CUVEN_MAX_LIGHTS];
    for (uint k = 0; k < CUVEN_MAX_LIGHTS; ++k) {
        uint best = 0;
        float bestScore = 0.0f;
        for (uint i = 0; i < CUVEN_CELL_COUNT; ++i) {
            if (tgScore[i] > bestScore) { bestScore = tgScore[i]; best = i; }
        }
        if (bestScore < 0.02f) {
            candidates[k].position = float4(0.0f);
            candidates[k].color = float4(0.0f);
            continue;
        }
        const int bx = int(best % uint(CUVEN_CELLS_X));
        const int by = int(best / uint(CUVEN_CELLS_X));
        float2 centroid = float2(0.0f);
        float3 color = float3(0.0f);
        float weight = 0.0f;
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                const int x = bx + dx;
                const int y = by + dy;
                if (x < 0 || y < 0 || x >= CUVEN_CELLS_X || y >= CUVEN_CELLS_Y) { continue; }
                const uint i = uint(y * CUVEN_CELLS_X + x);
                const float w = tgScore[i];
                centroid += cellCenterUV(uint(x), uint(y)) * w;
                color += tgColor[i].rgb * w;
                weight += w;
            }
        }
        centroid /= max(weight, 1e-5f);
        color /= max(weight, 1e-5f);
        const float chroma = max(max(color.r, color.g), max(color.b, 1e-4f));
        const float radius = clamp(sqrt(weight / bestScore) * (0.6f / float(CUVEN_CELLS_X)), 0.04f, 0.3f);
        candidates[k].position = float4(centroid, radius, tgColor[best].a);
        candidates[k].color = float4(color / chroma, 1.0f);

        for (uint i = 0; i < CUVEN_CELL_COUNT; ++i) {
            const float2 d = cellCenterUV(i % uint(CUVEN_CELLS_X), i / uint(CUVEN_CELLS_X)) - centroid;
            tgScore[i] *= 1.0f - exp(-dot(d, d) / (2.0f * 0.12f * 0.12f));
        }
    }

    // Track the four slots over time
    const float dt = max(u.analysis.x, 0.0f);
    const float k = 1.0f - exp(-dt / 0.25f);
    bool used[CUVEN_MAX_LIGHTS] = { false, false, false, false };
    CuvenLightSource next[CUVEN_MAX_LIGHTS];
    for (uint s = 0; s < CUVEN_MAX_LIGHTS; ++s) {
        const CuvenLightSource p = scene->lights[s];
        int match = -1;
        float bestDistance = 0.22f;
        if (p.color.a > 0.001f) {
            for (uint c = 0; c < CUVEN_MAX_LIGHTS; ++c) {
                if (used[c] || candidates[c].color.a <= 0.0f) { continue; }
                const float d = distance(p.position.xy, candidates[c].position.xy);
                if (d < bestDistance) { bestDistance = d; match = int(c); }
            }
        }
        if (match >= 0) {
            used[match] = true;
            const CuvenLightSource c = candidates[match];
            next[s].position = mix(p.position, c.position, k);
            next[s].color = float4(mix(p.color.rgb, c.color.rgb, k), mix(p.color.a, 1.0f, k));
        } else {
            next[s] = p;
            next[s].color.a = p.color.a * (1.0f - k);
        }
    }
    for (uint c = 0; c < CUVEN_MAX_LIGHTS; ++c) {
        if (used[c] || candidates[c].color.a <= 0.0f) { continue; }
        uint slot = 0;
        float weakest = 2.0f;
        for (uint s = 0; s < CUVEN_MAX_LIGHTS; ++s) {
            if (next[s].color.a < weakest) { weakest = next[s].color.a; slot = s; }
        }
        if (weakest < 0.15f) {
            next[slot].position = candidates[c].position;
            next[slot].color = float4(candidates[c].color.rgb, k);
            used[c] = true;
        }
    }
    for (uint s = 0; s < CUVEN_MAX_LIGHTS; ++s) {
        scene->lights[s] = next[s];
    }
}
