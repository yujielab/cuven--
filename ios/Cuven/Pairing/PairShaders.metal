#include <metal_stdlib>
using namespace metal;

// Cuven 光学配对：解码网络（逐层卷积）、粒子云（朗之万一步 + 画点）、相机帧 → 蓝色程度
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

// ── 粒子云 ──

static float pair_hash(float n) { return fract(sin(n) * 43758.5453123f); }

struct PairStepParams { float eps; float swirl; float frame; float ext; uint n; };

// 一步朗之万：x += ε·∇log ρ + √(2ε)·噪声 + κ·ε·(∇log ρ)⊥（最后一项沿等密度线流动，不改分布）
// field：r = ρ/ρmax，g、b = ∇log ρ；纹理坐标 (0, 0) 是 (−ext, −ext)
kernel void pair_step(device float2* pos [[buffer(0)]],
                      constant PairStepParams& p [[buffer(1)]],
                      texture2d<float> field [[texture(0)]],
                      uint id [[thread_position_in_grid]]) {
    if (id >= p.n) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
    float2 q = pos[id];
    float4 f = field.sample(s, q / (2.0f * p.ext) + 0.5f);
    float2 g = f.gb;
    float fid = float(id);
    float u1 = max(pair_hash(fid * 0.1031f + p.frame * 1.7f), 1e-6f), u2 = pair_hash(fid * 0.3713f + p.frame * 2.9f + 7.0f);
    float2 nz = sqrt(-2.0f * log(u1)) * float2(cos(6.2831853f * u2), sin(6.2831853f * u2));
    q += p.eps * g + sqrt(2.0f * p.eps) * nz + p.swirl * p.eps * float2(-g.y, g.x);
    float r = length(q);
    if (r > p.ext * 0.97f) q *= (p.ext * 0.97f) / r;
    pos[id] = q;
}

struct PairDrawParams { float rot; float scale; float size; float ext; float breath; float2 aspect; float3 light; float3 deep; };
struct PairVOut { float4 position [[position]]; float size [[point_size]]; float dense; float alpha; };

vertex PairVOut pair_vertex(uint vid [[vertex_id]],
                            device const float2* pos [[buffer(0)]],
                            constant PairDrawParams& p [[buffer(1)]],
                            texture2d<float> field [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
    float2 a = pos[vid];
    float c = cos(p.rot), sn = sin(p.rot);
    float2 q = float2(c * a.x - sn * a.y, sn * a.x + c * a.y);
    PairVOut o;
    // y 朝下画：和相机拍屏幕（行号往下）同一手性 —— 训练时就是这么看的，反过来是镜像，旋转找不回来
    o.position = float4(q.x * p.scale * p.aspect.x, -q.y * p.scale * p.aspect.y, 0.0f, 1.0f);
    float depth = pair_hash(float(vid) * 0.7311f);
    o.size = p.size * (0.7f + 0.6f * depth);
    o.dense = field.sample(s, a / (2.0f * p.ext) + 0.5f).r;
    o.alpha = (0.45f + 0.35f * depth) * p.breath;
    return o;
}

fragment float4 pair_fragment(PairVOut in [[stage_in]], float2 pc [[point_coord]], constant PairDrawParams& p [[buffer(1)]]) {
    float m = smoothstep(0.5f, 0.2f, length(pc - 0.5f));
    float3 col = mix(p.light, p.deep, clamp(in.dense * 1.6f - 0.2f, 0.0f, 1.0f));
    float a = in.alpha * m;
    return float4(col * a, a);                       // 预乘透明度
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
