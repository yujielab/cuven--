// Cuven 的视频着色器
//
// 两遍：
//   PS_Convert：解码出来的 Y / UV 平面（NV12 / P010）→ 中间纹理（FP16，片子原始尺寸）。只在来了新帧时跑。
//     · YCbCr → R'G'B'（BT.601 / 709 / 2020，有限 / 完整范围，按位深归一）
//     · 杜比视界 5（IPTPQc2）：按 RPU 的分段多项式 / MMR 重塑，再 IPT→LMS'→（PQ）→ LMS → BT.2020
//     · PQ / HLG → 线性尼特；BT.2020 → BT.709；BT.2390 色调映射（maxRGB，保色相）
//     · 输出：SDR 屏 → 伽马编码（BT.1886 反函数），HDR 屏 → scRGB（线性，1.0 = 80 尼特）
//   PS_Present：中间纹理 → 交换链。放大用 Catmull-Rom（9 次双线性取样），缩小双线性；叠字幕层；8 位输出加有序抖动

static const float PQ_M1 = 0.1593017578125;
static const float PQ_M2 = 78.84375;
static const float PQ_C1 = 0.8359375;
static const float PQ_C2 = 18.8515625;
static const float PQ_C3 = 18.6875;

cbuffer Convert : register(b0)
{
    float4 m0;              // R' = dot(m0.xyz, yuv) + m0.w
    float4 m1;
    float4 m2;
    float2 uvScale;         // 显示区域 → 纹理坐标
    float2 uvOffset;
    float2 chromaShift;     // 色度取样位置的偏移（左对齐 = 半个亮度像素）
    float bitScale;         // P010：65535 / 65472
    int mode;               // 0 SDR，1 PQ，2 HLG，3 杜比视界
    int outHdr;             // 0 SDR 屏，1 scRGB
    int gamut;              // 1 = BT.2020 → BT.709
    int tonemap;            // 1 = BT.2390
    float srcPeak;          // 片子的峰值（尼特）
    float dstPeak;          // 目标：SDR 屏 = 参考白，HDR 屏 = 屏幕峰值
    float sdrWhite;         // HDR 屏上 SDR 白多亮（尼特）
    float srcPQ;            // pq(srcPeak)
    float dstPQ;            // pq(dstPeak)
};

// 杜比视界 5 的 RPU（每帧一份，C++ 那边从 AVDOVIMetadata 摊平）
cbuffer Dovi : register(b1)
{
    float4 dv_nonlinear[3];     // IPT → LMS'（行）
    float4 dv_offset;
    float4 dv_linear[3];        // LMS → BT.2020 RGB（行）
    int4 dv_pivots;             // 每个分量的支点数
    float4 dv_piv[9];           // 分量 c 的第 k 个支点：dv_piv[c * 3 + k / 4][k % 4]
    float4 dv_info[24];         // (c * 8 + 段)：x = 0 多项式 / 1 MMR，y = 阶数，z = MMR 常数项
    float4 dv_poly[24];         // xyz = c0 c1 c2
    float4 dv_mmr[144];         // ((c * 8 + 段) * 3 + 阶) * 2 + 0/1：7 个系数（x y z xy | xz yz xyz）
};

Texture2D<float> tY : register(t0);
Texture2D<float2> tUV : register(t1);
SamplerState sLinear : register(s0);
SamplerState sPoint : register(s1);

struct VOut
{
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

// 一个盖满全屏的三角形
VOut VS_Full(uint id : SV_VertexID)
{
    VOut o;
    o.uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(o.uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return o;
}

float3 pq_eotf(float3 e)
{
    float3 p = pow(max(e, 0.0), 1.0 / PQ_M2);
    return pow(max(p - PQ_C1, 0.0) / max(PQ_C2 - PQ_C3 * p, 1e-6), 1.0 / PQ_M1);
}

float pq_eotf1(float e)
{
    float p = pow(max(e, 0.0), 1.0 / PQ_M2);
    return pow(max(p - PQ_C1, 0.0) / max(PQ_C2 - PQ_C3 * p, 1e-6), 1.0 / PQ_M1);
}

float pq_oetf1(float y)
{
    float p = pow(max(y, 0.0), PQ_M1);
    return pow((PQ_C1 + PQ_C2 * p) / (1.0 + PQ_C3 * p), PQ_M2);
}

// HLG：反 OETF + OOTF（1000 尼特，γ = 1.2）→ 尼特
float3 hlg_to_nits(float3 e)
{
    const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
    float3 lo = e * e / 3.0;
    float3 hi = (exp((e - c) / a) + b) / 12.0;
    float3 s = float3(e.x <= 0.5 ? lo.x : hi.x, e.y <= 0.5 ? lo.y : hi.y, e.z <= 0.5 ? lo.z : hi.z);
    float ys = dot(s, float3(0.2627, 0.6780, 0.0593));
    return 1000.0 * pow(max(ys, 1e-6), 0.2) * s;
}

float3 bt2020_to_709(float3 c)
{
    return float3(dot(c, float3(1.660491, -0.587641, -0.072850)),
                  dot(c, float3(-0.124550, 1.132900, -0.008349)),
                  dot(c, float3(-0.018151, -0.100579, 1.118730)));
}

// BT.2390 EETF（PQ 域）：x 是尼特
float eetf(float x)
{
    float e = pq_oetf1(x / 10000.0) / srcPQ;
    float maxLum = dstPQ / srcPQ;
    float ks = 1.5 * maxLum - 0.5;
    if (e > ks)
    {
        float t = (e - ks) / max(1.0 - ks, 1e-6);
        float t2 = t * t, t3 = t2 * t;
        e = (2.0 * t3 - 3.0 * t2 + 1.0) * ks + (t3 - 2.0 * t2 + t) * (1.0 - ks) + (-2.0 * t3 + 3.0 * t2) * maxLum;
    }
    return pq_eotf1(min(e, 1.0) * srcPQ) * 10000.0;
}

float3 tone_map(float3 rgb)
{
    float m = max(rgb.r, max(rgb.g, rgb.b));
    if (m <= 1e-4 || srcPeak <= dstPeak) return rgb;
    return rgb * (eetf(m) / m);
}

float dv_pivot(int c, int k)
{
    float4 q = dv_piv[c * 3 + (k >> 2)];
    int j = k & 3;
    return j == 0 ? q.x : j == 1 ? q.y : j == 2 ? q.z : q.w;
}

float dv_reshape(int c, float3 s)
{
    float v = c == 0 ? s.x : c == 1 ? s.y : s.z;
    int np = c == 0 ? dv_pivots.x : c == 1 ? dv_pivots.y : dv_pivots.z;
    if (np < 2) return v;
    v = clamp(v, dv_pivot(c, 0), dv_pivot(c, np - 1));
    int piece = 0;
    [loop] for (int k = 1; k < np - 1; k++)
        if (v >= dv_pivot(c, k)) piece = k;
    int idx = c * 8 + piece;
    float4 info = dv_info[idx];
    if (info.x < 0.5)
    {
        float3 p = dv_poly[idx].xyz;
        return p.x + v * (p.y + v * p.z);
    }
    float3 x = s;
    float4 xy = float4(x.x * x.y, x.x * x.z, x.y * x.z, x.x * x.y * x.z);
    float r = info.z;
    float3 xp = x;
    float4 xyp = xy;
    int order = (int)info.y;
    [unroll] for (int o = 0; o < 3; o++)
    {
        if (o < order)
        {
            int base = (idx * 3 + o) * 2;
            float4 a = dv_mmr[base];
            float4 b = dv_mmr[base + 1];
            r += dot(a, float4(xp, xyp.x)) + dot(b.xyz, xyp.yzw);
        }
        xp *= x;
        xyp *= xy;
    }
    return r;
}

float4 PS_Convert(VOut i) : SV_Target
{
    float2 tc = i.uv * uvScale + uvOffset;
    float y = tY.SampleLevel(sLinear, tc, 0);
    float2 cbcr = tUV.SampleLevel(sLinear, tc + chromaShift, 0);
    float3 yuv = float3(y, cbcr) * bitScale;
    float3 rgb;
    if (mode == 3)
    {
        float3 r = float3(dv_reshape(0, yuv), dv_reshape(1, yuv), dv_reshape(2, yuv));
        float3 d = r - dv_offset.xyz;
        float3 lmsP = float3(dot(dv_nonlinear[0].xyz, d), dot(dv_nonlinear[1].xyz, d), dot(dv_nonlinear[2].xyz, d));
        float3 lms = pq_eotf(saturate(lmsP));
        rgb = float3(dot(dv_linear[0].xyz, lms), dot(dv_linear[1].xyz, lms), dot(dv_linear[2].xyz, lms)) * 10000.0;
    }
    else
    {
        float3 e = float3(dot(m0.xyz, yuv) + m0.w, dot(m1.xyz, yuv) + m1.w, dot(m2.xyz, yuv) + m2.w);
        if (mode == 1) rgb = pq_eotf(saturate(e)) * 10000.0;
        else if (mode == 2) rgb = hlg_to_nits(saturate(e));
        else rgb = e;
    }

    float3 o;
    if (mode >= 1)
    {
        // HDR 片：线性尼特、BT.2020
        if (gamut) rgb = bt2020_to_709(rgb);
        if (tonemap) rgb = tone_map(rgb);
        if (outHdr) o = rgb / 80.0;
        else o = pow(saturate(rgb / dstPeak), 1.0 / 2.4);
    }
    else
    {
        // SDR 片
        if (outHdr)
        {
            float3 lin = pow(saturate(rgb), 2.4);
            if (gamut) lin = bt2020_to_709(lin);
            o = lin * (sdrWhite / 80.0);
        }
        else
        {
            o = saturate(rgb);
        }
    }
    return float4(o, 1.0);
}

// ── 第二遍：上屏 ──────────────────────────────────────────────

cbuffer Present : register(b2)
{
    float4 dst;             // 画面在目标里的矩形（像素）：x y w h
    float2 srcSize;         // 中间纹理尺寸
    float2 targetSize;
    int pOutHdr;
    int bicubic;
    int hasSubs;
    float subGain;          // HDR 屏上字幕多亮（SDR 白 / 80）
};

Texture2D<float4> tVideo : register(t0);
Texture2D<float4> tSubs : register(t1);

// Catmull-Rom：9 次双线性取样代替 16 次（MJP 的写法）
float3 sample_bicubic(float2 uv)
{
    float2 samplePos = uv * srcSize;
    float2 texPos1 = floor(samplePos - 0.5) + 0.5;
    float2 f = samplePos - texPos1;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 offset12 = w2 / w12;
    float2 texPos0 = (texPos1 - 1.0) / srcSize;
    float2 texPos3 = (texPos1 + 2.0) / srcSize;
    float2 texPos12 = (texPos1 + offset12) / srcSize;
    float3 r = 0;
    r += tVideo.SampleLevel(sLinear, float2(texPos0.x, texPos0.y), 0).rgb * w0.x * w0.y;
    r += tVideo.SampleLevel(sLinear, float2(texPos12.x, texPos0.y), 0).rgb * w12.x * w0.y;
    r += tVideo.SampleLevel(sLinear, float2(texPos3.x, texPos0.y), 0).rgb * w3.x * w0.y;
    r += tVideo.SampleLevel(sLinear, float2(texPos0.x, texPos12.y), 0).rgb * w0.x * w12.y;
    r += tVideo.SampleLevel(sLinear, float2(texPos12.x, texPos12.y), 0).rgb * w12.x * w12.y;
    r += tVideo.SampleLevel(sLinear, float2(texPos3.x, texPos12.y), 0).rgb * w3.x * w12.y;
    r += tVideo.SampleLevel(sLinear, float2(texPos0.x, texPos3.y), 0).rgb * w0.x * w3.y;
    r += tVideo.SampleLevel(sLinear, float2(texPos12.x, texPos3.y), 0).rgb * w12.x * w3.y;
    r += tVideo.SampleLevel(sLinear, float2(texPos3.x, texPos3.y), 0).rgb * w3.x * w3.y;
    return r;
}

// 8×8 Bayer（0..1）
float bayer(float2 p)
{
    uint2 q = uint2(p) & 7;
    uint v = 0;
    uint x = q.x, y = q.y ^ q.x;
    v = ((y & 1) << 5) | ((x & 1) << 4) | ((y & 2) << 2) | ((x & 2) << 1) | ((y & 4) >> 1) | ((x & 4) >> 2);
    return (v + 0.5) / 64.0;
}

float4 PS_Present(VOut i) : SV_Target
{
    float2 p = i.pos.xy;
    float3 c = 0;
    float2 uv = (p - dst.xy) / dst.zw;
    if (all(uv >= 0.0) && all(uv <= 1.0))
        c = bicubic ? sample_bicubic(uv) : tVideo.SampleLevel(sLinear, uv, 0).rgb;
    if (hasSubs)
    {
        float4 s = tSubs.SampleLevel(sPoint, p / targetSize, 0);
        float3 sc = s.rgb;
        if (pOutHdr && s.a > 0.0) sc = pow(saturate(s.rgb / s.a), 2.2) * s.a * subGain;
        c = c * (1.0 - s.a) + sc;
    }
    if (!pOutHdr) c += (bayer(p) - 0.5) / 255.0;
    return float4(c, 1.0);
}
