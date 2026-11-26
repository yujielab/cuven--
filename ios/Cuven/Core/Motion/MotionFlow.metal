#include <metal_stdlib>
using namespace metal;

// 自研运动补偿插帧（Core/Motion/）的着色器。函数名都带 mf_ 前缀。
//
// 分析（每对相邻的片源帧 A、B 一次，计算着色器）：
//   亮度金字塔 L0（约 960 宽）… L3 → 最粗一层全搜索 → 逐层细化 + 邻块传播（块 8×8，「双边」匹配：以中间帧为锚，
//   对中间帧上的位置 p 找 v，使 A(p − v/2) 与 B(p + v/2) 最像）→ 块中值 → 在半尺寸那一层上逐像素从周围 2×2 个块的
//   向量里挑最合的 → 中值 → 可信度图（匹配残差对局部对比度，2×2 取最小再柔化）。
// 重建（屏幕每刷新一次，片元着色器直接画到屏上）：
//   按这一刻落在 A、B 之间的位置 φ：运动可靠处，细节取时间上更近的那一帧（A(p − φv) 或 B(p + (1−φ)v)，锐利取样），
//   大块明暗在两帧之间平滑过渡；不可靠或两边对不上处退回「时间上更近的原帧」（中间那一段有神经中间帧、
//   且它不是重影时取它）；静止处直接取原帧。
//
// 坐标一律归一化（0…1，纹素中心在 (i+0.5)/N），向量是 A→B 的归一化位移。算法先用 numpy 在真实 1080p50 片段上
// 验证过（抽掉一半的帧再插回来和真实帧比），这里的每个 kernel 和那份参考实现一一对应。

constexpr sampler mfLinear(coord::normalized, address::clamp_to_edge, filter::linear);

struct MFParams {
    float4 search;   // x 最粗层搜索半径（纹素），y 窗口每边几个采样点，z 零向量偏好（每纹素），w 偏离父块的代价（每纹素）
    float4 refine;   // x 细化一步的代价（每纹素），y 再细化几步（1 到半像素，2 到四分之一像素），z 对比度系数 kc，w 噪声底 n0
    float4 extra;    // x 窗口采样点的间距（纹素），y、z 可信度的软门限，w 四个块的向量差在这以内（基层像素）就直接取平均
};

// MARK: 金字塔

/// 片源亮度平面 → 分析基层（任意整数倍缩小：2×2 个线性采样点，各自平均 2×2 个纹素）
kernel void mf_luma_base(texture2d<float, access::sample> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         ushort2 gid [[thread_position_in_grid]]) {
    float2 size = float2(dst.get_width(), dst.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    float2 q = 0.25 / size;
    float v = src.sample(mfLinear, uv + float2(-q.x, -q.y), level(0)).r
            + src.sample(mfLinear, uv + float2( q.x, -q.y), level(0)).r
            + src.sample(mfLinear, uv + float2(-q.x,  q.y), level(0)).r
            + src.sample(mfLinear, uv + float2( q.x,  q.y), level(0)).r;
    dst.write(float4(v * 0.25, 0, 0, 1), uint2(gid));
}

/// 基层亮度 → (亮度, 局部对比度：3×3 的最大减最小)
kernel void mf_pack_contrast(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             ushort2 gid [[thread_position_in_grid]]) {
    int2 size = int2(src.get_width(), src.get_height());
    int2 p = int2(gid);
    float lo = 1e9, hi = -1e9;
    for (int j = -1; j <= 1; ++j) {
        for (int i = -1; i <= 1; ++i) {
            float v = src.read(uint2(clamp(p + int2(i, j), int2(0), size - 1))).r;
            lo = min(lo, v);
            hi = max(hi, v);
        }
    }
    dst.write(float4(src.read(uint2(p)).r, hi - lo, 0, 1), uint2(gid));
}

/// 2×2 平均缩小一半
kernel void mf_down2(texture2d<float, access::sample> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     ushort2 gid [[thread_position_in_grid]]) {
    float2 ssize = float2(src.get_width(), src.get_height());
    float2 uv = (float2(gid) * 2.0 + 1.0) / ssize;
    dst.write(float4(src.sample(mfLinear, uv, level(0)).r, 0, 0, 1), uint2(gid));
}

// MARK: 块匹配

/// 窗口内的平均绝对差：A(c + o − v/2) 对 B(c + o + v/2)。win 是每边几个采样点，spacing 是它们的间距（纹素）：
/// 8 点、间距 1 是完整的 8×8；4 点、间距 2 落在像素的角上，每个双线性采样平均 2×2 个像素，同样盖住 8×8，采样只要四分之一
/// （真机上一对帧要 25～35 ms，太慢；numpy 里两种窗口的结果只差约 0.05 dB）
static float mf_cost(texture2d<float, access::sample> A, texture2d<float, access::sample> B,
                     float2 c, float2 v, float2 texel, int win, float spacing) {
    float2 h = v * 0.5;
    float s = 0.0;
    float half_win = (float(win) - 1.0) * 0.5;
    for (int j = 0; j < win; ++j) {
        for (int i = 0; i < win; ++i) {
            float2 p = c + (float2(float(i), float(j)) - half_win) * spacing * texel;
            s += fabs(A.sample(mfLinear, p - h, level(0)).r - B.sample(mfLinear, p + h, level(0)).r);
        }
    }
    return s / float(win * win);
}

/// 最粗一层：全搜索
kernel void mf_search_coarse(texture2d<float, access::sample> A [[texture(0)]],
                             texture2d<float, access::sample> B [[texture(1)]],
                             texture2d<float, access::write> outField [[texture(2)]],
                             constant MFParams &P [[buffer(0)]],
                             ushort2 gid [[thread_position_in_grid]]) {
    float2 fsize = float2(outField.get_width(), outField.get_height());
    float2 texel = 1.0 / float2(A.get_width(), A.get_height());
    float2 c = (float2(gid) + 0.5) / fsize;
    int R = int(P.search.x);
    int win = int(P.search.y);
    float best = 1e9;
    float2 bv = float2(0.0);
    for (int dy = -R; dy <= R; ++dy) {
        for (int dx = -R; dx <= R; ++dx) {
            float2 d = float2(float(dx), float(dy));
            float2 v = 2.0 * d * texel;
            float e = mf_cost(A, B, c, v, texel, win, P.extra.x) + P.search.z * 2.0 * length(d);
            if (e < best) { best = e; bv = v; }
        }
    }
    outField.write(float4(bv, best, 1), uint2(gid));
}

/// 在 bv 周围 ±step 纹素（每帧各挪半步）找更好的。返回 xy 向量、z 代价
static float3 mf_step(texture2d<float, access::sample> A, texture2d<float, access::sample> B,
                      float2 c, float2 bv, float2 texel, int win, float spacing, float step, float lam) {
    float best = mf_cost(A, B, c, bv, texel, win, spacing);
    float2 out = bv;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            if (dx == 0 && dy == 0) { continue; }
            float2 d = float2(float(dx), float(dy));
            float2 v = bv + 2.0 * step * d * texel;
            float e = mf_cost(A, B, c, v, texel, win, spacing) + lam * 2.0 * step * length(d);
            if (e < best) { best = e; out = v; }
        }
    }
    return float3(out, best);
}

/// 细一层：从父块和它的四邻（再加零向量）里挑，再 ±1 细化（最细一层再 ±0.5）
kernel void mf_refine(texture2d<float, access::sample> A [[texture(0)]],
                      texture2d<float, access::sample> B [[texture(1)]],
                      texture2d<float, access::read> parent [[texture(2)]],
                      texture2d<float, access::write> outField [[texture(3)]],
                      constant MFParams &P [[buffer(0)]],
                      ushort2 gid [[thread_position_in_grid]]) {
    float2 fsize = float2(outField.get_width(), outField.get_height());
    float2 isize = float2(A.get_width(), A.get_height());
    float2 texel = 1.0 / isize;
    int2 psize = int2(parent.get_width(), parent.get_height());
    float2 c = (float2(gid) + 0.5) / fsize;
    int win = int(P.search.y);
    int2 pj = clamp(int2(c * float2(psize)), int2(0), psize - 1);
    float2 c0 = parent.read(uint2(pj)).xy;

    int2 offs[5] = { int2(0, 0), int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
    float best = 1e9;
    float2 bv = c0;
    for (int k = 0; k < 6; ++k) {
        float2 v = float2(0.0);
        if (k < 5) { v = parent.read(uint2(clamp(pj + offs[k], int2(0), psize - 1))).xy; }
        float e = mf_cost(A, B, c, v, texel, win, P.extra.x) + P.search.w * length((v - c0) * isize);
        if (e < best) { best = e; bv = v; }
    }
    float3 r = mf_step(A, B, c, bv, texel, win, P.extra.x, 1.0, P.refine.x);
    if (P.refine.y > 0.5) {
        r = mf_step(A, B, c, r.xy, texel, win, P.extra.x, 0.5, P.refine.x);
    }
    if (P.refine.y > 1.5) {
        r = mf_step(A, B, c, r.xy, texel, win, P.extra.x, 0.25, P.refine.x);
    }
    outField.write(float4(r, 1), uint2(gid));
}

/// 同一层再传一遍：试四邻的向量，再 ±1（最细一层再 ±0.5）
kernel void mf_propagate(texture2d<float, access::sample> A [[texture(0)]],
                         texture2d<float, access::sample> B [[texture(1)]],
                         texture2d<float, access::read> field [[texture(2)]],
                         texture2d<float, access::write> outField [[texture(3)]],
                         constant MFParams &P [[buffer(0)]],
                         ushort2 gid [[thread_position_in_grid]]) {
    int2 fs = int2(field.get_width(), field.get_height());
    float2 isize = float2(A.get_width(), A.get_height());
    float2 texel = 1.0 / isize;
    float2 c = (float2(gid) + 0.5) / float2(fs);
    int win = int(P.search.y);
    int2 p = int2(gid);
    float2 own = field.read(uint2(p)).xy;
    float best = mf_cost(A, B, c, own, texel, win, P.extra.x);
    float2 bv = own;
    int2 offs[4] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
    for (int k = 0; k < 4; ++k) {
        float2 v = field.read(uint2(clamp(p + offs[k], int2(0), fs - 1))).xy;
        float e = mf_cost(A, B, c, v, texel, win, P.extra.x) + P.search.w * 0.5 * length((v - own) * isize);
        if (e < best) { best = e; bv = v; }
    }
    float3 r = mf_step(A, B, c, bv, texel, win, P.extra.x, 1.0, P.refine.x);
    if (P.refine.y > 0.5) {
        r = mf_step(A, B, c, r.xy, texel, win, P.extra.x, 0.5, P.refine.x);
    }
    if (P.refine.y > 1.5) {
        r = mf_step(A, B, c, r.xy, texel, win, P.extra.x, 0.25, P.refine.x);
    }
    outField.write(float4(r, 1), uint2(gid));
}

/// 9 个数的中值（逐分量），排序网络
static float2 mf_median9(float2 v0, float2 v1, float2 v2, float2 v3, float2 v4, float2 v5, float2 v6, float2 v7, float2 v8) {
#define MF_SORT2(a, b) { float2 t = min(a, b); b = max(a, b); a = t; }
    MF_SORT2(v1, v2) MF_SORT2(v4, v5) MF_SORT2(v7, v8)
    MF_SORT2(v0, v1) MF_SORT2(v3, v4) MF_SORT2(v6, v7)
    MF_SORT2(v1, v2) MF_SORT2(v4, v5) MF_SORT2(v7, v8)
    MF_SORT2(v0, v3) MF_SORT2(v5, v8) MF_SORT2(v4, v7)
    MF_SORT2(v3, v6) MF_SORT2(v1, v4) MF_SORT2(v2, v5)
    MF_SORT2(v4, v7) MF_SORT2(v4, v2) MF_SORT2(v6, v4)
    MF_SORT2(v4, v2)
#undef MF_SORT2
    return v4;
}

/// 3×3 中值（xy），z 原样带过去
kernel void mf_median(texture2d<float, access::read> field [[texture(0)]],
                      texture2d<float, access::write> outField [[texture(1)]],
                      ushort2 gid [[thread_position_in_grid]]) {
    int2 fs = int2(field.get_width(), field.get_height());
    int2 p = int2(gid);
    float2 v[9];
    int n = 0;
    for (int j = -1; j <= 1; ++j) {
        for (int i = -1; i <= 1; ++i) {
            v[n++] = field.read(uint2(clamp(p + int2(i, j), int2(0), fs - 1))).xy;
        }
    }
    float2 m = mf_median9(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8]);
    outField.write(float4(m, field.read(uint2(p)).z, 1), uint2(gid));
}

// MARK: 逐像素的向量、可信度

/// 逐像素的向量（在半尺寸那一层上做，A、B 是那一层的亮度）：周围 2×2 个块的向量里，3×3 窗口上双边匹配最好的那个。
/// 四个向量本来就差不多（大多数像素）时直接取双线性平均，不逐个试。零向量总要试一下
/// （压在运动背景上的硬字幕、台标：笔画本身没动）；要明显更合才选它。输出 xy 向量、z 残差
kernel void mf_densify(texture2d<float, access::sample> A [[texture(0)]],
                       texture2d<float, access::sample> B [[texture(1)]],
                       texture2d<float, access::read> field [[texture(2)]],
                       texture2d<float, access::write> outDense [[texture(3)]],
                       constant MFParams &P [[buffer(0)]],
                       ushort2 gid [[thread_position_in_grid]]) {
    float2 size = float2(outDense.get_width(), outDense.get_height());
    float2 isize = float2(A.get_width(), A.get_height());
    float2 texel = 1.0 / isize;
    int2 fs = int2(field.get_width(), field.get_height());
    float2 u = (float2(gid) + 0.5) / size;
    float2 g = u * float2(fs) - 0.5;
    float2 g0 = floor(g);
    float2 f = g - g0;
    int2 i0 = int2(g0);
    float2 cand[4];
    cand[0] = field.read(uint2(clamp(i0, int2(0), fs - 1))).xy;
    cand[1] = field.read(uint2(clamp(i0 + int2(1, 0), int2(0), fs - 1))).xy;
    cand[2] = field.read(uint2(clamp(i0 + int2(0, 1), int2(0), fs - 1))).xy;
    cand[3] = field.read(uint2(clamp(i0 + int2(1, 1), int2(0), fs - 1))).xy;
    float2 bv = mix(mix(cand[0], cand[1], f.x), mix(cand[2], cand[3], f.x), f.y);
    float bestErr = mf_cost(A, B, u, bv, texel, 3, 1.0);
    float current = bestErr;
    // 向量差（换算成基层像素：基层是这一层的两倍）
    float2 spread = (max(max(cand[0], cand[1]), max(cand[2], cand[3])) - min(min(cand[0], cand[1]), min(cand[2], cand[3])))
                    * isize * 2.0;
    if (max(spread.x, spread.y) >= P.extra.w) {
        float best = 1e9;
        for (int k = 0; k < 4; ++k) {
            float e = mf_cost(A, B, u, cand[k], texel, 3, 1.0);
            float biased = e + 0.002 * length(f - float2(float(k & 1), float(k >> 1)));
            if (biased < best) { best = biased; bestErr = e; bv = cand[k]; }
        }
        current = best;
    }
    float ez = mf_cost(A, B, u, float2(0.0), texel, 3, 1.0);
    if (ez + 0.003 < current) { bestErr = ez; bv = float2(0.0); }
    outDense.write(float4(bv, bestErr, 1), uint2(gid));
}

/// 可信度（输出是逐像素向量那一层的一半）：2×2 个像素里最差的那个；残差对「局部对比度 × kc + 噪声底」的比值过软门限
kernel void mf_trust(texture2d<float, access::read> dense [[texture(0)]],
                     texture2d<float, access::sample> packedA [[texture(1)]],
                     texture2d<float, access::sample> packedB [[texture(2)]],
                     texture2d<float, access::write> outTrust [[texture(3)]],
                     constant MFParams &P [[buffer(0)]],
                     ushort2 gid [[thread_position_in_grid]]) {
    int2 ds = int2(dense.get_width(), dense.get_height());
    float2 dsize = float2(ds);
    float t = 1.0;
    for (int j = 0; j < 2; ++j) {
        for (int i = 0; i < 2; ++i) {
            int2 p = min(int2(gid) * 2 + int2(i, j), ds - 1);
            float4 d = dense.read(uint2(p));
            float2 u = (float2(p) + 0.5) / dsize;
            float act = max(packedA.sample(mfLinear, u - d.xy * 0.5, level(0)).g,
                            packedB.sample(mfLinear, u + d.xy * 0.5, level(0)).g);
            float ratio = d.z / (P.refine.z * act + P.refine.w);
            t = min(t, 1.0 - smoothstep(P.extra.y, P.extra.z, ratio));
        }
    }
    outTrust.write(float4(t, 0, 0, 1), uint2(gid));
}

/// 3×3 平均
kernel void mf_blur3(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     ushort2 gid [[thread_position_in_grid]]) {
    int2 size = int2(src.get_width(), src.get_height());
    int2 p = int2(gid);
    float s = 0.0;
    for (int j = -1; j <= 1; ++j) {
        for (int i = -1; i <= 1; ++i) {
            s += src.read(uint2(clamp(p + int2(i, j), int2(0), size - 1))).r;
        }
    }
    dst.write(float4(s / 9.0, 0, 0, 1), uint2(gid));
}

// MARK: 重建（画到屏上）

struct MFDraw {
    float4 phase;    // x φ，y 模式（0 只画 A；1 插帧；2 插帧 + 神经中间帧），z 诊断分区图（1 = 开），w 1 = 画面要放大（原帧也用锐利取样）
    float4 uv;       // xy 缩放，zw 偏移：屏上的 uv → 片源的 uv
    float4 gate;     // x、y 两边对不上的软门限，z 对比度系数 kc，w 噪声底 n0
    float4 weights;  // x、y 运动补偿时大块明暗从 A 过渡到 B 的区间，z、w 没用
    float4 range;    // x 亮度缩放，y 亮度偏移，z 色度缩放，w 色度偏移（码值 → 归一化）
    float4 toR;      // YCbCr → R'G'B' 的三行（xyz）
    float4 toG;
    float4 toB;
};

struct MFVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex MFVertexOut mf_vertex(uint vid [[vertex_id]]) {
    MFVertexOut o;
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

static float3 mf_ycc(texture2d<float, access::sample> Y, texture2d<float, access::sample> C, float2 uv) {
    return float3(Y.sample(mfLinear, uv, level(0)).r, C.sample(mfLinear, uv, level(0)).rg);
}

/// 亮度的锐利取样（Catmull-Rom 双三次，去掉四个角的 5 次双线性采样）。按运动挪了不到一个像素、或者 1080p 放大到屏幕时，
/// 双线性取样会把细节抹软：真机反馈「模糊」。numpy 里量过：插出来的帧的清晰度从真实帧的约 86% 回到约 95%
static float mf_y_sharp(texture2d<float, access::sample> Y, float2 uv) {
    float2 size = float2(Y.get_width(), Y.get_height());
    float2 pos = uv * size;
    float2 p1 = floor(pos - 0.5) + 0.5;
    float2 f = pos - p1;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 t0 = (p1 - 1.0) / size;
    float2 t3 = (p1 + 2.0) / size;
    float2 t12 = (p1 + w2 / w12) / size;
    float wc = w12.x * w12.y;
    float wl = w0.x * w12.y;
    float wr = w3.x * w12.y;
    float wu = w12.x * w0.y;
    float wd = w12.x * w3.y;
    float v = Y.sample(mfLinear, float2(t12.x, t12.y), level(0)).r * wc
            + Y.sample(mfLinear, float2(t0.x, t12.y), level(0)).r * wl
            + Y.sample(mfLinear, float2(t3.x, t12.y), level(0)).r * wr
            + Y.sample(mfLinear, float2(t12.x, t0.y), level(0)).r * wu
            + Y.sample(mfLinear, float2(t12.x, t3.y), level(0)).r * wd;
    return saturate(v / (wc + wl + wr + wu + wd));
}

static float3 mf_ycc_sharp(texture2d<float, access::sample> Y, texture2d<float, access::sample> C, float2 uv) {
    return float3(mf_y_sharp(Y, uv), C.sample(mfLinear, uv, level(0)).rg);
}

fragment float4 mf_present(MFVertexOut in [[stage_in]],
                           texture2d<float, access::sample> yA [[texture(0)]],
                           texture2d<float, access::sample> cA [[texture(1)]],
                           texture2d<float, access::sample> yB [[texture(2)]],
                           texture2d<float, access::sample> cB [[texture(3)]],
                           texture2d<float, access::sample> packedA [[texture(4)]],
                           texture2d<float, access::sample> packedB [[texture(5)]],
                           texture2d<float, access::sample> dense [[texture(6)]],
                           texture2d<float, access::sample> trust [[texture(7)]],
                           texture2d<float, access::sample> yN [[texture(8)]],
                           texture2d<float, access::sample> cN [[texture(9)]],
                           constant MFDraw &D [[buffer(0)]]) {
    float2 uv = in.uv * D.uv.xy + D.uv.zw;
    float phi = D.phase.x;
    float3 ycc = float3(0.0);
    float3 tint = float3(0.0);
    float routed = 0.0;
    bool sharpen = D.phase.w > 0.5;
    if (D.phase.y < 0.5) {
        ycc = sharpen ? mf_ycc_sharp(yA, cA, uv) : mf_ycc(yA, cA, uv);
    } else {
        float2 v = dense.sample(mfLinear, uv, level(0)).xy;
        bool done = false;
        if (dot(v, v) < 1e-8) {
            // 这一处没动：两帧在这里本来就一样的话，直接取时间上更近的那张原帧（大多数像素走这条，省一大半采样）
            float2 pa = packedA.sample(mfLinear, uv, level(0)).rg;
            float2 pb = packedB.sample(mfLinear, uv, level(0)).rg;
            float still = fabs(pa.r - pb.r) / (D.gate.z * max(pa.g, pb.g) + D.gate.w);
            if (still < D.gate.x) {
                if (phi < 0.5) {
                    ycc = sharpen ? mf_ycc_sharp(yA, cA, uv) : mf_ycc(yA, cA, uv);
                } else {
                    ycc = sharpen ? mf_ycc_sharp(yB, cB, uv) : mf_ycc(yB, cB, uv);
                }
                done = true;
            }
        }
        if (!done) {
            // 向量场锚在中间帧上：挪到这一刻（一次不动点迭代）
            float k = phi - 0.5;
            float2 uv2 = uv - k * v;
            v = dense.sample(mfLinear, uv2, level(0)).xy;
            float t = trust.sample(mfLinear, uv2, level(0)).r;
            float2 ua = uv - phi * v;
            float2 ub = uv + (1.0 - phi) * v;
            float2 pa = packedA.sample(mfLinear, ua, level(0)).rg;
            float2 pb = packedB.sample(mfLinear, ub, level(0)).rg;
            float conflict = smoothstep(D.gate.x, D.gate.y, fabs(pa.r - pb.r) / (D.gate.z * max(pa.g, pb.g) + D.gate.w));
            float r = max(conflict, 1.0 - t);
            float3 mc = float3(0.0);
            if (r < 0.999) {
                // 分频混合：细节只取时间上更近的那一帧（按运动对好位），大块的明暗（半尺寸的亮度）在两帧之间平滑过渡。
                // 两帧各取一半再混，稍微没对齐就糊；这样每一刻都一样清楚，大的形状也不会在中点跳一下
                float w = smoothstep(D.weights.x, D.weights.y, phi);
                float low = pb.r - pa.r;
                float2 chroma = mix(cA.sample(mfLinear, ua, level(0)).rg, cB.sample(mfLinear, ub, level(0)).rg, w);
                float luma = phi < 0.5 ? mf_y_sharp(yA, ua) + w * low : mf_y_sharp(yB, ub) - (1.0 - w) * low;
                mc = float3(luma, chroma);
            }
            float3 fb = float3(0.0);
            if (r > 0.001) {
                // 信不过的地方：时间上更近的那张原帧，原地不动（等于这里不插帧）
                if (phi < 0.5) { fb = mf_ycc_sharp(yA, cA, uv); } else { fb = mf_ycc_sharp(yB, cB, uv); }
                if (D.phase.y > 1.5) {
                    // 神经中间帧只在中间那一段用；它在这里要是只是 A、B 叠在一起（重影），就不用它
                    float wn = smoothstep(0.2, 0.3, phi) * (1.0 - smoothstep(0.7, 0.8, phi));
                    if (wn > 0.001) {
                        float3 n = mf_ycc(yN, cN, uv);
                        float al = packedA.sample(mfLinear, uv, level(0)).r;
                        float bl = packedB.sample(mfLinear, uv, level(0)).r;
                        float ghost = 1.0 - smoothstep(0.15, 0.35, fabs(n.x - 0.5 * (al + bl)) / (fabs(al - bl) + 0.02));
                        fb = mix(fb, n, wn * (1.0 - ghost));
                    }
                }
            }
            ycc = mix(mc, fb, r);
            // 分区图：红 = 退回原帧 / 神经中间帧，绿 = 运动补偿；没动的地方不染色（画面原色）
            tint = mix(float3(0.0, 1.0, 0.2), float3(1.0, 0.1, 0.0), r);
            routed = max(r, smoothstep(0.0005, 0.002, length(v)));
        }
    }
    float y = (ycc.x - D.range.y) * D.range.x;
    float2 c = (ycc.yz - D.range.w) * D.range.z;
    float3 yuv = float3(y, c);
    float3 rgb = float3(dot(D.toR.xyz, yuv), dot(D.toG.xyz, yuv), dot(D.toB.xyz, yuv));
    rgb = saturate(rgb);
    if (D.phase.z > 0.5) { rgb = mix(rgb, tint, 0.3 * routed); }
    return float4(rgb, 1.0);
}
