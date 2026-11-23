#include <metal_stdlib>
using namespace metal;

// Cuven 光学配对：解码网络（逐层卷积）、粒子云（复刻的 3D 云 + 码的调制）、相机帧 → 蓝色程度
// 设计见 PairCodec.swift / PairNet.swift / PairCloud.swift

struct PairConvParams { uint cin; uint cout; uint h; uint w; int dr; int da; uint woff; uint boff; };

// 3×3 空洞卷积 + ReLU：角向（x）首尾相接，径向（y）补 0。数据布局 [通道][行][列]
kernel void pair_conv(device const float* inp [[buffer(0)]],
                      device float* outp [[buffer(1)]],
                      device const float* wts [[buffer(2)]],
                      constant PairConvParams& p [[buffer(3)]],
                      uint3 gid [[thread_position_in_grid]]) {
    uint x = gid.x, y = gid.y, co = gid.z;
    if (x >= p.w || y >= p.h || co >= p.cout) return;
    float acc = wts[p.boff + co];
    int W = int(p.w), H = int(p.h);
    for (uint ci = 0; ci < p.cin; ci++) {
        for (int ky = 0; ky < 3; ky++) {
            int yy = int(y) + (ky - 1) * p.dr;
            if (yy < 0 || yy >= H) continue;
            uint rowBase = (ci * p.h + uint(yy)) * p.w;
            uint wBase = p.woff + ((co * p.cin + ci) * 3 + uint(ky)) * 3;
            for (int kx = 0; kx < 3; kx++) {
                int xx = (int(x) + (kx - 1) * p.da) % W;
                if (xx < 0) xx += W;
                acc += wts[wBase + uint(kx)] * inp[rowBase + uint(xx)];
            }
        }
    }
    outp[(co * p.h + y) * p.w + x] = max(acc, 0.0f);
}

// 1×1 卷积 + tanh（最后一层）
kernel void pair_head(device const float* inp [[buffer(0)]],
                      device float* outp [[buffer(1)]],
                      device const float* wts [[buffer(2)]],
                      constant PairConvParams& p [[buffer(3)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.w || gid.y >= p.h) return;
    uint i = gid.y * p.w + gid.x, n = p.h * p.w;
    float acc = wts[p.boff];
    for (uint ci = 0; ci < p.cin; ci++) acc += wts[p.woff + ci] * inp[ci * n + i];
    outp[i] = tanh(acc);
}

// ── 粒子云（照 Apple 配对动画复刻的那一版，和网页 web/pair.js 的着色器逐行一致）──
// 3D 球壳 + 光晕 + 12 缕丝，绕斜轴滚动、几层剪切把壳「折」起来，10 秒一个循环；逐帧光学密度校正（pair-density.png）。
// 码：每个粒子的光学深度乘上屏幕上那一点的 M（码平面 y 朝下、慢慢转）—— 不透明度 1 − (1 − a)^(增益·M)

struct PairCloudUniforms {
    float4 scaleCenter;     // xy：云半径 → NDC 的比例；zw：中心
    float4 params;          // 粒子大小比例、相位、浓淡（gathering）、码平面范围
    float4 codeRotDensity;  // xy：码平面的 cos / sin；zw：密度图一帧占的比例
    float4 densityOrigins;  // 这一帧、下一帧在密度图里的左上角
    float4 misc;            // x：两帧之间的插值；y：码纹理里存的是 M / codeScale
};
struct PairParticle { float4 position; float4 detail; };
struct PairCloudOut {
    float4 position [[position]];
    float size [[point_size]];
    float4 color;
    float2 cloudUv;
    float2 codeUv;
};

static float2 pair_turn(float2 v, float angle) { float c = cos(angle), s = sin(angle); return float2(c * v.x - s * v.y, s * v.x + c * v.y); }

static float3 pair_roll(float3 point, float phase) {
    float3 axis = normalize(float3(0.17f, 0.98f, 0.09f));
    float latitude = dot(point, axis);
    float slip = 0.16f * latitude + (0.075f + 0.14f * latitude * latitude) * sin(phase * 2.0f + 2.5f * latitude);
    float angle = phase + slip + 0.105f * sin(2.0f * phase - 0.38f);
    float c = cos(angle);
    float3 rolled = point * c + cross(axis, point) * sin(angle) + axis * latitude * (1.0f - c);
    rolled.xy = pair_turn(rolled.xy, 0.085f * sin(phase + 0.8f) + 0.036f * sin(3.0f * phase));
    return rolled;
}

static float3 pair_flow(float3 p, float phase, float strength) {
    float3 drift = sin(phase * float3(2.0f, -1.0f, 2.0f) + float3(0.4f, 1.9f, 4.3f));
    float3 q = p + strength * 0.109f * sin(p.yzx * float3(7.0f, 6.7f, 6.2f) + p.zxy * float3(3.2f, 3.7f, 2.8f)
                                          + phase * float3(2.0f, -1.0f, 2.0f) + float3(2.0f, 0.5f, 4.4f) + drift);
    q += strength * 0.054f * sin(q.zxy * float3(11.0f, 12.0f, 11.5f) + q.yzx * 4.2f + phase * float3(-2.0f, 3.0f, -3.0f) + float3(1.0f, 5.0f, 2.1f));
    q += strength * 0.024f * sin(q.yzx * 21.0f + q.zxy * 8.0f + phase * float3(3.0f, 3.0f, -3.0f));
    return q;
}

static float3 pair_wisp(PairParticle pt, float phase, float variation, thread float &taper) {
    float angle = pt.position.x, elevation = pt.position.y, along = pt.position.z, idPhase = pt.position.w;
    float seed = pt.detail.x, spread = pt.detail.y, depthSpread = pt.detail.z;
    angle += 0.14f * sin(phase * 2.0f + idPhase) + 0.06f * sin(phase * 3.0f - idPhase);
    elevation += 0.12f * sin(phase * 2.0f - idPhase) + 0.055f * cos(phase * 3.0f + 1.7f * idPhase);
    float ce = cos(elevation);
    float3 normal = float3(ce * cos(angle), ce * sin(angle), sin(elevation));
    float3 tangent = float3(-sin(angle), cos(angle), 0.0f);
    float3 bitangent = cross(normal, tangent);
    float tilt = 0.75f * sin(idPhase * 1.7f) + 0.32f * sin(phase * 2.0f + idPhase);
    float3 across = tangent * cos(tilt) + bitangent * sin(tilt);
    float3 sideways = cross(normal, across);
    float len = 0.46f + 0.14f * sin(idPhase) + 0.07f * sin(phase * 3.0f + idPhase);
    float arc = len * along + 0.026f * sin(along * 6.0f - phase * 2.0f + idPhase);
    float curl = 0.19f * (along * along - 0.25f) + 0.083f * sin(along * 3.2f + phase * 3.0f + idPhase) + 0.033f * sin(along * 8.0f - phase * 2.0f + idPhase);
    float gathering = 0.5f + 0.5f * sin(phase * 3.0f + idPhase + 0.53f * along);
    gathering = 0.25f + 0.75f * gathering * gathering;
    float width = (0.009f + 0.022f * seed) * (0.85f + 0.47f * along * along) + (1.0f - variation * gathering) * 0.046f;
    taper = (1.0f - smoothstep(0.49f, 1.0f, abs(along))) * gathering;
    float radius = 0.91f + 0.073f * sin(idPhase * 2.4f + phase * 2.0f) + 0.056f * sin(along * 4.5f + idPhase);
    return (radius + depthSpread * width * 0.86f) * (normal * cos(arc) + across * sin(arc)) + sideways * (curl + spread * width);
}

vertex PairCloudOut pair_cloud_vertex(uint vid [[vertex_id]],
                                     device const PairParticle* particles [[buffer(0)]],
                                     constant PairCloudUniforms& u [[buffer(1)]]) {
    PairParticle pt = particles[vid];
    float phase = u.params.y, variation = u.params.z;
    float kind = pt.detail.w, seed = pt.detail.x, taper = 1.0f;
    float3 point; float strength;
    if (kind > 1.5f) { point = pair_wisp(pt, phase, variation, taper); strength = 0.84f; }
    else {
        point = pt.position.xyz;
        float wave = sin(dot(point, float3(4.4f, -3.5f, 2.7f)) + phase * 2.0f);
        float lobe = sin(dot(point, float3(2.1f, 4.6f, -3.7f)) - phase * 3.0f);
        point *= 1.0f + 0.058f * wave + 0.042f * lobe;
        strength = kind < 0.5f ? 1.0f : 0.51f;
    }
    point = pair_flow(point, phase, strength * (0.62f + variation * 0.43f));
    float3 pockets = sin(point.yzx * 7.3f + point.zxy * 5.1f + phase * float3(1.0f, -2.0f, 1.0f));
    float shade = 0.5f + dot(pockets, float3(0.1667f));
    point = pair_roll(point, phase);
    point *= 1.0f + 0.018f * sin(phase * 3.0f) + 0.011f * cos(phase * 5.0f);
    float perspective = 1.0f / (1.0f - 0.14f * point.z);
    float2 projected = point.xy * perspective;
    PairCloudOut o;
    o.position = float4(projected * u.scaleCenter.xy + u.scaleCenter.zw, 0.0f, 1.0f);
    o.cloudUv = float2(projected.x, -projected.y) / 2.90f + 0.5f;
    float2 cp = float2(projected.x, -projected.y);
    float2 cr = u.codeRotDensity.xy;
    o.codeUv = float2(cr.x * cp.x - cr.y * cp.y, cr.y * cp.x + cr.x * cp.y) / (2.0f * u.params.w) + 0.5f;
    float size = 1.87f + 1.70f * seed * seed + 0.50f * seed;
    float opacity = 0.32f + 0.19f * (1.0f - seed);
    float grain = kind > 1.5f ? fract(pt.position.w * 0.618f + seed * 17.181f) : pt.detail.z;
    float3 blue = mix(float3(0.096f, 0.470f, 0.722f), float3(0.124f, 0.673f, 0.912f), grain);
    opacity *= (0.57f + 0.72f * shade) * (0.91f + 0.25f * point.z);
    if (kind > 1.5f) {
        blue = mix(float3(0.042f, 0.522f, 0.828f), float3(0.108f, 0.648f, 0.924f), grain);
        opacity *= (0.22f + 2.40f * taper) * (0.21f + 0.79f * variation);
        opacity *= 0.63f + 0.37f * smoothstep(-0.75f, 0.36f, point.z);
        size *= 0.86f;
    } else if (kind > 0.5f) {
        blue = mix(float3(0.21f, 0.45f, 0.59f), float3(0.29f, 0.63f, 0.74f), grain);
        float haloFade = 1.0f - smoothstep(1.14f, 1.64f, length(point));
        opacity *= (0.40f + 0.45f * pt.detail.y) * haloFade;
        size *= 0.82f;
    } else {
        opacity *= 1.16f * pt.detail.y;
    }
    float pixelSize = size * u.params.x * perspective;
    opacity *= min(1.0f, pixelSize * pixelSize * 0.69f);
    o.size = max(1.20f, pixelSize);
    o.color = float4(blue, min(opacity, 0.95f));
    return o;
}

fragment float4 pair_cloud_fragment(PairCloudOut in [[stage_in]], float2 pc [[point_coord]],
                                    constant PairCloudUniforms& u [[buffer(1)]],
                                    texture2d<float> density [[texture(0)]],
                                    texture2d<float> code [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
    float coverage = 1.0f - smoothstep(0.08f, 0.5f, length(pc - 0.5f));
    float2 offset = clamp(in.cloudUv, 0.0f, 1.0f) * u.codeRotDensity.zw;
    float before = density.sample(s, u.densityOrigins.xy + offset).r;
    float after = density.sample(s, u.densityOrigins.zw + offset).r;
    float correction = (mix(before, after, u.misc.x) * 255.0f - 128.0f) / 44.0f;
    float gain = exp2(0.90f * correction) * code.sample(s, clamp(in.codeUv, 0.0f, 1.0f)).r * u.misc.y;   // 光学深度 × M
    float opacity = 1.0f - pow(max(1.0f - in.color.a * coverage, 0.0f), gain);
    return float4(in.color.rgb, opacity);
}

// ── 相机帧 → 蓝色程度（B − R），裁正中间的正方形、缩成 dst × dst ──
struct PairInkParams { uint ox; uint oy; uint side; uint dst; float scale; };

kernel void pair_ink(texture2d<float, access::read> cam [[texture(0)]],
                     device float* outp [[buffer(0)]],
                     constant PairInkParams& p [[buffer(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.dst || gid.y >= p.dst) return;
    float step = float(p.side) / float(p.dst);
    uint k = max(1u, uint(step));
    uint x0 = p.ox + uint(float(gid.x) * step), y0 = p.oy + uint(float(gid.y) * step);
    uint W = cam.get_width(), H = cam.get_height();
    float acc = 0.0f; uint cnt = 0;
    for (uint j = 0; j < k; j++) {
        for (uint i = 0; i < k; i++) {
            uint xx = x0 + i, yy = y0 + j;
            if (xx >= W || yy >= H) continue;
            float4 c = cam.read(uint2(xx, yy));
            acc += max(c.b - c.r, 0.0f); cnt++;
        }
    }
    outp[gid.y * p.dst + gid.x] = clamp(acc / float(max(cnt, 1u)) * p.scale, 0.0f, 1.0f);
}
