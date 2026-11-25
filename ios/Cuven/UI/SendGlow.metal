#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// 「申请添加」上滑发送的光（用户要求：上滑或按下申请添加 → 粒子箭头飞行动效、屏幕显示「正在发往请求中心」→ 打勾、
// 显示「已添加至请求中心」和时间；参照用户发来的录屏和 Swipe-to-Send 设计说明，一帧一帧对过）。
// 这一个文件有两样东西：
//   1. sg_vertex / sg_fragment：SendGlowCanvas 那块全屏 MTKView 的一遍全屏片元着色器 —— 近黑的圆角视口、
//      发送中的蓝紫色云 + 发光的粒子箭头（白芯 + 柔的外光，一路往上、慢慢变小变柔）+ 往箭头里汇过去的一粒粒火星、
//      添加成功那一下从结果那一组中心往外走的一道环（走到屏幕圆角边上时带一点绿 / 琥珀色边）、
//      然后贴着圆角边的一圈内光（亮边是短边的 3%，往里羽化），颜色慢慢从紫往青漂。
//   2. cuvenSendRefraction：SwiftUI layerEffect 用的 [[ stitchable ]] 函数 —— 环扫过结果那一组时，
//      带里的像素沿半径方向挪一下、R / G / B 各挪各的（设计说明里的「折射」），几帧就过去。
// 所有函数名带 sg_ 前缀，常量带 kSG 前缀（和别的 .metal 编进同一个库，不撞名）。

constant float3 kSGInk = float3(0.0431, 0.0431, 0.0706);     // #0B0B12
constant float3 kSGBlue = float3(0.259, 0.388, 1.0);          // #4263FF
constant float3 kSGViolet = float3(0.510, 0.408, 1.0);        // #8268FF
constant float3 kSGCyan = float3(0.443, 0.851, 1.0);          // #71D9FF
constant float3 kSGMagenta = float3(0.78, 0.36, 0.95);        // 云两边一缕缕偏玫紫的光（录屏里有）

struct SGUniforms {
    float4 size;    // x 宽（像素），y 高，z 圆角半径（像素），w 慢漂的时间（秒；减弱动态效果时停住）
    float4 focus;   // xy 结果那一组的中心（像素），z 帧号（抖动用），w 1 = 失败那种平静的边缘光（灰紫、不呼吸）
    float4 arrow;   // xy 箭头尖（像素），z 箭头半宽（像素），w 箭头亮度 0…1
    float4 cloud;   // x 云顶（像素：再往上羽化成黑），y 云的亮度 0…1，z 箭头和光核变柔了几成 0…1，w 闲置时底边那一点光 0…1
    float4 ring;    // x 环半径（像素），y 环的亮度 0…1，z 环宽（像素，高斯 σ），w 绿 / 琥珀色边 0…1
    float4 edge;    // x 边缘光亮度 0…1，y 往青色漂了几成 0…1，z 结果出来那一下中心的闪光 0…1，w 粒子的时间（秒，从松手算起）
};

struct SGOut {
    float4 pos [[position]];
    float2 uv;
};

vertex SGOut sg_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    SGOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// MARK: 噪声

static float sg_hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float sg_hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

static float sg_noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = sg_hash21(i), b = sg_hash21(i + float2(1.0, 0.0));
    float c = sg_hash21(i + float2(0.0, 1.0)), d = sg_hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// 四层的分形噪声（0…1）：云的一团团、一缕缕
static float sg_fbm(float2 p) {
    float s = 0.0, a = 0.5, n = 0.0;
    for (int i = 0; i < 4; i++) {
        s += a * sg_noise(p);
        n += a;
        p = p * 2.03 + float2(17.1, 9.2);
        a *= 0.5;
    }
    return s / n;
}

/// 圆角矩形的有向距离（里面是负的）
static float sg_round_box(float2 p, float2 b, float r) {
    r = min(r, min(b.x, b.y));
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

/// 点到线段的距离（x）和投影在线段上的位置（y：0 = a，1 = b）
static float2 sg_segment(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1.0e-4));
    return float2(length(pa - ba * h), h);
}

/// 光可以叠到 1 以上：0.6 以下照原样，往上慢慢压到 1；很亮的地方往白里溢一点（箭头的芯、环最亮的地方发白，不是一片死蓝）
static float3 sg_tone(float3 c) {
    float m = max(c.r, max(c.g, c.b));
    c += max(m - 1.0, 0.0) * 0.35;
    float3 k = max(c - 0.6, 0.0);
    return min(c, 0.6) + 0.4 * (1.0 - exp(-k / 0.4));
}

// MARK: 发送中

/// 云：屏幕下面一大片蓝紫色的光，一缕一缕竖着的（像极光的帘子），慢慢往上飘；往上羽化成黑，中间高、两边低一点（一个圆顶）；
/// 箭头底下一团发白的光核，再往下一点偏青（参照录屏 3.27 秒那一帧）
static float3 sg_cloud(float2 px, constant SGUniforms &U, float S, float T) {
    float W = U.size.x;
    float2 q = float2((px.x - 0.5 * W) / S, px.y / S);
    float xr = (px.x - U.arrow.x) / S;
    float top = U.cloud.x / S + 0.35 * xr * xr;
    float mask = smoothstep(top, top + 0.42, q.y);
    float3 c = float3(0.0);
    if (mask > 0.0) {
        float t = T * 0.16;
        float2 w = float2(sg_fbm(q * 1.3 + float2(0.0, t)), sg_fbm(q * 1.3 + float2(4.7, -t * 0.8)));
        // 横向频率比竖向高：一缕一缕竖着的；整片慢慢往上走（采样的 y 随时间往下挪）
        float n1 = sg_fbm(float2(q.x * 2.0, q.y * 0.75 + t * 1.5) + w * 1.4);
        float n2 = sg_fbm(float2(q.x * 1.2 + 3.1, q.y * 1.1 + t) + w * 0.8);
        // 大团的明暗（录屏里云是一大团一大团的，不是细碎的）
        float blob = sg_fbm(float2(q.x * 0.9 - 2.3, q.y * 0.8 + t * 0.9) + w * 0.6);
        float3 tint = mix(kSGBlue, kSGViolet, smoothstep(0.30, 0.70, n2));
        tint = mix(tint, kSGMagenta, smoothstep(0.60, 0.85, n1) * smoothstep(0.12, 0.45, abs(xr)) * 0.55);
        tint = mix(tint, kSGCyan, smoothstep(0.58, 0.85, n2) * 0.35);
        float body = (0.35 + 0.75 * smoothstep(0.25, 0.80, n1)) * (0.45 + 0.95 * smoothstep(0.30, 0.72, blob));
        float depth = smoothstep(top, top + 0.9, q.y);
        float centre = 0.6 + 0.4 * exp(-xr * xr / 0.20);
        c = tint * body * mask * (0.70 + 0.45 * depth) * centre;
    }
    // 光核：箭头正下方一团发白的光（随箭头一起变小），再往下一点偏青
    float hw = max(U.arrow.z, 1.0);
    float soft = U.cloud.z;
    float2 dc = (px - float2(U.arrow.x, U.arrow.y + hw * 0.75)) / (hw * (1.25 + 0.35 * soft));
    float core = exp(-dot(dc * float2(1.0, 1.2), dc * float2(1.0, 1.2)));
    float2 dh = (px - float2(U.arrow.x, U.arrow.y + hw * 1.35)) / (hw * 0.45);
    float hot = exp(-dot(dh, dh));
    c += mix(float3(0.62, 0.62, 1.0), kSGCyan, 0.15) * core * (0.75 - 0.2 * soft);
    c += kSGCyan * hot * 0.45;
    return c;
}

/// 一颗颗沿着箭头笔画往箭头尖跑的亮点（「粒子箭头」：芯不是一根光滑的线，是一串往上流的光点）
static float sg_beads(float h, float n, float t, float seed) {
    float ph = h * n + t * 2.2 + seed * 0.37;     // t 越大，同一颗亮点的 h 越小：往箭头尖跑
    float f = fract(ph);
    float z = (f - 0.5) / 0.17;
    float g = exp(-z * z);
    float b = 0.45 + 0.55 * sg_hash11(floor(ph) * 13.7 + seed * 5.1);
    return g * b;
}

/// 箭头：一个扁的「^」加一根往下渐隐的竖杆；白芯（一串往上流的光点）+ 柔的蓝紫外光
static float3 sg_arrow(float2 px, constant SGUniforms &U) {
    float2 A = U.arrow.xy;
    float hw = max(U.arrow.z, 1.0);
    float soft = U.cloud.z;
    float t = U.edge.w;
    float2 L = A + float2(-hw, 0.52 * hw);
    float2 R = A + float2(hw, 0.52 * hw);
    float2 B = A + float2(0.0, 1.0 * hw);
    float2 sl = sg_segment(px, A, L);
    float2 sr = sg_segment(px, A, R);
    float2 sb = sg_segment(px, A, B);
    float cw = hw * (0.072 + 0.050 * soft);
    float bw = hw * (0.30 + 0.20 * soft);
    // 两条臂到头那一截淡一点、钝一点；竖杆越往下越淡，没进光核里
    float tl = 1.0 - 0.55 * smoothstep(0.55, 1.0, sl.y);
    float tr = 1.0 - 0.55 * smoothstep(0.55, 1.0, sr.y);
    float tb = mix(1.0, 0.12, sb.y);
    float cl = exp(-(sl.x * sl.x) / (cw * cw)) * tl * (0.45 + 0.9 * sg_beads(sl.y, 7.0, t, 1.0));
    float cr = exp(-(sr.x * sr.x) / (cw * cw)) * tr * (0.45 + 0.9 * sg_beads(sr.y, 7.0, t, 2.0));
    float cb = exp(-(sb.x * sb.x) / (cw * cw * 0.7225)) * tb * (0.45 + 0.9 * sg_beads(sb.y, 6.0, t, 3.0));
    float core = max(max(cl, cr), cb);
    float d = min(min(sl.x, sr.x), sb.x + hw * 0.25 * sb.y);
    float bloom = exp(-d / bw);
    // 箭头尖上一点最亮的光
    float tip = exp(-dot(px - A, px - A) / (cw * cw * 9.0));
    return float3(1.0, 0.98, 1.0) * (core * (2.1 - 0.5 * soft) + tip * 0.6) + float3(0.55, 0.55, 1.0) * bloom * (0.50 - 0.15 * soft);
}

/// 火星：云里一粒粒小光点往上飘，越往上越往箭头那条竖轴收（像被吸进箭头里）；过了箭头尖就没了
static float3 sg_sparks(float2 px, constant SGUniforms &U, float S) {
    float2 rel = (px - U.arrow.xy) / S;
    if (rel.y < -0.08) return float3(0.0);
    float t = U.edge.w;
    // 同一粒火星在「收拢后的坐标」里是固定的，整块坐标往上卷：在屏幕上看就是一边往上飘、一边往竖轴靠
    float w = mix(0.28, 1.0, saturate(rel.y / 0.8));
    float2 Q = float2(rel.x / w, rel.y + t * 0.30);
    const float cs = 0.05;
    float2 cell = floor(Q / cs);
    float acc = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 id = cell + float2(float(i), float(j));
            float h3 = sg_hash21(id + 41.9);
            if (h3 < 0.70) continue;                   // 七成的格子空着：疏疏落落
            float h1 = sg_hash21(id), h2 = sg_hash21(id + 17.3);
            float2 p = (id + 0.15 + 0.7 * float2(h1, h2)) * cs;
            // 竖着拉长一点：往上飞的一道道细光，不是一片雪
            float2 dd = float2((Q.x - p.x) * w, (Q.y - p.y) * 0.4);
            float r = 0.003 + 0.0035 * h1;
            float tw = 0.55 + 0.45 * sin(t * (5.0 + 6.0 * h2) + h1 * 40.0);
            acc += exp(-dot(dd, dd) / (r * r)) * tw * (h3 - 0.70) * 2.2;
        }
    }
    float fade = smoothstep(-0.08, 0.03, rel.y) * (1.0 - smoothstep(0.6, 1.15, rel.y));
    return float3(0.82, 0.86, 1.0) * acc * fade;
}

// MARK: 一遍画完

fragment float4 sg_fragment(SGOut in [[stage_in]], constant SGUniforms &U [[buffer(0)]]) {
    float2 px = in.pos.xy;
    float W = U.size.x, H = U.size.y;
    float S = max(min(W, H), 1.0);
    float T = U.size.w;
    float2 mid = float2(W, H) * 0.5;

    // 圆角视口：外面纯黑（屏幕本来就是圆角，这一圈在玻璃外面），边上一个像素的抗锯齿
    float sd = sg_round_box(px - mid, mid, U.size.z);
    float clip = saturate(0.5 - sd);
    if (clip <= 0.0) return float4(0.0, 0.0, 0.0, 1.0);

    // 离结果那一组中心多远；环和边缘光共用一点起伏（环不是正圆，边缘一段一段亮起来，参照录屏 5.0–5.23 秒）
    float2 fd = px - U.focus.xy;
    float fr = length(fd);
    float2 fdir = fr > 0.5 ? fd / fr : float2(0.0, -1.0);
    float wob = (sg_noise(fdir * 1.7 + float2(T * 0.35, 3.0)) - 0.5) * min(S * (0.03 + 0.09 * saturate(U.ring.x / S)), 0.35 * U.ring.x);
    float rw = fr + wob;

    // 底色：近黑，结果那一组周围再暗一点（字最清楚）
    float3 base = kSGInk * (1.0 - 0.5 * exp(-(fr * fr) / (0.2025 * S * S)));
    float3 light = float3(0.0);

    // 闲置：底边一点很淡的青紫光（胶囊那儿）
    if (U.cloud.w > 0.001) {
        float e = max(-sd, 0.0);
        float g = exp(-e / (0.05 * S)) * smoothstep(0.55 * H, H, px.y);
        light += mix(kSGCyan, kSGViolet, smoothstep(0.2 * W, 0.8 * W, px.x)) * g * 0.35 * U.cloud.w;
    }

    // 发送中：云、火星、箭头
    if (U.cloud.y > 0.001) light += sg_cloud(px, U, S, T) * U.cloud.y;
    if (U.arrow.w > 0.001) {
        light += sg_sparks(px, U, S) * U.arrow.w;
        light += sg_arrow(px, U) * U.arrow.w;
    }

    // 成功：中心闪一下，一道环往外走，走到边上时外沿带一点绿 / 琥珀
    if (U.edge.z > 0.001) {
        float fl = exp(-(fr * fr) / (0.0576 * S * S));
        light += mix(float3(0.30, 0.80, 0.72), kSGViolet, smoothstep(0.05 * S, 0.22 * S, fr)) * fl * 0.42 * U.edge.z;
    }
    if (U.ring.y > 0.001) {
        float x = (rw - U.ring.x) / max(U.ring.z, 1.0);
        float band = exp(-x * x) + 0.22 * exp(-x * x / 6.0);      // 软的一圈，外面再拖一层很淡的光晕
        float ang = atan2(fd.y, fd.x);
        float3 rc = mix(kSGBlue, kSGViolet, 0.5 + 0.5 * sin(ang * 2.0 + T * 1.5));
        rc = mix(rc, kSGCyan, 0.25 * (1.0 - smoothstep(-1.2, 0.0, x)));
        float k = sg_noise(fdir * 2.3 + float2(11.0, 5.0));
        float3 fringe = mix(float3(0.30, 0.95, 0.55), float3(1.0, 0.70, 0.30), smoothstep(0.35, 0.65, k));
        rc = mix(rc, fringe, saturate(U.ring.w * smoothstep(-0.3, 1.0, x)) * 0.9);
        light += rc * band * U.ring.y * 1.05;
    }

    // 边缘光：贴着圆角边的一圈亮边（短边的 3%）往里羽化；环走到哪儿，哪一段边就亮起来（刚亮的那一下更亮）；
    // 之后慢慢从紫往青漂，左右两边颜色不一样（参照录屏 5.6、7.0 秒）
    if (U.edge.x > 0.001) {
        float e = max(-sd, 0.0);
        if (e < 0.5 * S) {
            float rimW = 0.03 * S;
            float rim = exp(-(e * e) / (rimW * rimW));
            float feather = exp(-e / (rimW * 3.0));
            float haze = exp(-e / (0.20 * S));
            float2 dm = px - mid;
            float ang = atan2(dm.y, dm.x);
            float drift = U.edge.y;
            float cy = saturate(0.10 + 0.30 * drift + (0.25 + 0.15 * drift) * sin(ang + T * 0.22));
            float3 fcol = mix(mix(kSGViolet, kSGBlue, 0.35 + 0.25 * sin(ang * 2.0 - T * 0.15)), kSGCyan, cy);
            float3 rcol = mix(fcol, float3(1.0), 0.55);
            if (U.focus.w > 0.5) {
                // 失败：一圈很淡的灰紫，不庆祝
                fcol = float3(0.40, 0.40, 0.52);
                rcol = fcol * 1.3;
            }
            float passed = U.ring.x - rw;
            float arrive = smoothstep(-0.02 * S, 0.16 * S, passed);
            float boost = 1.0 + 0.7 * U.ring.y * exp(-max(passed, 0.0) / (0.2 * S));
            // 失败那一圈不呼吸：平静、不动（画面落定以后画布就停下不画了）
            float breathe = U.focus.w > 0.5 ? 1.0 : 0.93 + 0.07 * sin(T * 0.9 + ang * 2.0);
            light += (rcol * rim * 1.15 + fcol * feather * 0.55 + fcol * haze * 0.10) * U.edge.x * arrive * boost * breathe;
        }
    }

    float3 c = base + sg_tone(light);
    c *= clip;
    // 抖动半个色阶：暗处的大片渐变不出色带
    c += (sg_hash21(px + float2(U.focus.z * 7.31, U.focus.z * 3.17)) - 0.5) * (1.5 / 255.0);
    return float4(saturate(c), 1.0);
}

// MARK: SwiftUI 的折射（layerEffect）

/// 环扫过结果那一组（勾、片名、那一行字、时间、按钮）时的折射（用户要求的动效，设计说明「Refraction follows the wave」）：
/// 一条软的带子（半径 radius、宽 width，都是点）里的像素沿半径方向往外挪 amount 点；R 挪得多、B 挪得少，带子里出一圈彩边。
/// 带子外面三次采样落在同一点，原样输出。position、center 都是这一组自己的坐标（点）。
[[ stitchable ]] half4 cuvenSendRefraction(float2 position, SwiftUI::Layer layer,
                                           float2 center, float radius, float width, float amount) {
    float2 d = position - center;
    float r = length(d);
    float2 dir = r > 0.5 ? d / r : float2(0.0, -1.0);
    float x = (r - radius) / max(width, 1.0);
    float band = exp(-x * x);
    float2 off = dir * (amount * band);
    half4 cr = layer.sample(position - off * 1.35);
    half4 cg = layer.sample(position - off);
    half4 cb = layer.sample(position - off * 0.65);
    half a = max(max(cr.a, cg.a), cb.a);
    return half4(cr.r, cg.g, cb.b, a);
}
