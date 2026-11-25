#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// 「申请添加」上滑发送的光（用户要求：上滑或按下申请添加 → 粒子箭头飞行动效、屏幕显示「正在发往请求中心」→ 打勾、
// 显示「已添加至请求中心」和时间；参照用户发来的录屏和 Swipe-to-Send 设计说明，一帧一帧对过）。
// 这一个文件有两样东西：
//   1. sg_vertex / sg_fragment：SendGlowCanvas 那块全屏 MTKView 的一遍全屏片元着色器 —— 近黑的圆角视口、
//      发送中极光一样的气雾（几层域扭曲的分形噪声，慢慢往上流；上沿一团团地羽化成黑；箭头那一带最亮、
//      青 / 梅紫的色块；整体不爆白）+ 发光的箭头（一笔平滑的「^」+ 竖杆，白芯 + 很窄的柔光；竖杆尽头一团粉紫光，
//      往下拖一道淡紫的尾雾：「腾云驾雾」；一路往上、慢慢变小变柔）、
//      添加成功那一下从结果那一组中心往外走的一道环（走到屏幕圆角边上时带一点绿 / 琥珀色边）、
//      然后贴着圆角边的一圈内光（亮边是短边的 3%，往里羽化），颜色慢慢从紫往青漂。
//   2. cuvenSendRefraction：SwiftUI layerEffect 用的 [[ stitchable ]] 函数 —— 环扫过结果那一组时，
//      带里的像素沿半径方向挪一下、R / G / B 各挪各的（设计说明里的「折射」），几帧就过去。
// 所有函数名带 sg_ 前缀，常量带 kSG 前缀（和别的 .metal 编进同一个库，不撞名）。

constant float3 kSGInk = float3(0.0431, 0.0431, 0.0706);     // #0B0B12
constant float3 kSGBlue = float3(0.259, 0.388, 1.0);          // #4263FF
constant float3 kSGViolet = float3(0.510, 0.408, 1.0);        // #8268FF
constant float3 kSGCyan = float3(0.443, 0.851, 1.0);          // #71D9FF

// 发送中的气雾和箭头（照用户发来的录屏一帧一帧量的颜色；画布是 bgra8Unorm，这些 sRGB 值直接写出去）
constant float3 kSGNavy = float3(0.110, 0.173, 0.439);        // #1C2C70 气雾上沿羽化的那一圈
constant float3 kSGUpper = float3(0.188, 0.188, 0.604);       // #30309A 箭头上面那一片
constant float3 kSGAzure = float3(0.227, 0.314, 0.753);       // #3A50C0 箭头那一带（最亮）
constant float3 kSGIndigo = float3(0.267, 0.212, 0.784);      // #4436C8 箭头下面
constant float3 kSGDeepViolet = float3(0.247, 0.196, 0.659);  // #3F32A8 屏幕最下面
constant float3 kSGPeri = float3(0.353, 0.392, 0.886);        // #5A64E2 浓的那几团
constant float3 kSGTeal = float3(0.122, 0.627, 0.847);        // #1FA0D8 青的色块
constant float3 kSGPlum = float3(0.478, 0.322, 0.753);        // #7A52C0 两边偏上的梅紫色块
constant float3 kSGLavHi = float3(0.847, 0.659, 0.973);       // #D8A8F8 竖杆尽头那一团粉紫光
constant float3 kSGLav = float3(0.557, 0.486, 0.965);         // #8E7CF6 往下拖的尾雾
constant float3 kSGHalo = float3(0.239, 0.384, 0.914);        // #3D62E9 箭头笔画外面那一点光
constant float3 kSGCore = float3(0.933, 0.965, 1.0);          // #EEF6FF 箭头的白芯（偏冷）

struct SGUniforms {
    float4 size;    // x 宽（像素），y 高，z 圆角半径（像素），w 慢漂的时间（秒；减弱动态效果时停住）
    float4 focus;   // xy 结果那一组的中心（像素），z 帧号（抖动用），w 1 = 失败那种平静的边缘光（灰紫、不呼吸）
    float4 arrow;   // xy 箭头尖（像素），z 箭头半宽（像素），w 箭头亮度 0…1
    float4 cloud;   // x 云顶（像素：再往上羽化成黑），y 云的亮度 0…1，z 箭头和光核变柔了几成 0…1，w 闲置时底边那一点光 0…1
    float4 ring;    // x 环半径（像素），y 环的亮度 0…1，z 环宽（像素，高斯 σ），w 绿 / 琥珀色边 0…1
    float4 edge;    // x 边缘光亮度 0…1，y 往青色漂了几成 0…1，z 结果出来那一下中心的闪光 0…1，w 从松手算起的时间（秒；着色器现在不用，留着对齐）
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

static float sg_noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = sg_hash21(i), b = sg_hash21(i + float2(1.0, 0.0));
    float c = sg_hash21(i + float2(0.0, 1.0)), d = sg_hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// oct 层的分形噪声（0…1）：气雾的一团团（调用处都传常数 2 或 3，编译器展开）
static float sg_fbm(float2 p, int oct) {
    float s = 0.0, a = 0.5, n = 0.0;
    for (int i = 0; i < oct; i++) {
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

/// 往里羽化用的「离边多远」（里面是正的）：横、竖两条直边的距离做一次平滑取小，k 是圆滑的宽度（像素）。
/// 圆角矩形的精确距离在比圆角更深的地方等距线是直角，对角线上折出一道斜缝（边缘光看着像相框的接角，不像屏幕的圆角）；
/// 这个场深处的等距线也是圆的。k ≈ 1.17 × 圆角时贴边那一圈和那段圆弧差不到圆角的 1%
static float sg_edge_soft(float2 p, float2 b, float k) {
    float2 d = b - abs(p);
    float m = min(d.x, d.y);
    if (k <= 0.0) return m;
    float h = max(k - abs(d.x - d.y), 0.0) / k;
    return m - h * h * k * 0.25;
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

/// 发送中的光用的软肩：每个通道 0.82 以下照原样，往上慢慢压到 1；不往白里溢（录屏里只有箭头的芯是白的，气雾一直是饱和的蓝紫）
static float3 sg_knee(float3 c) {
    float3 e = max(c - 0.82, 0.0);
    return min(c, 0.82) + 0.18 * (1.0 - exp(-e / 0.18));
}

/// 按最亮的那个通道一起软压（色相不变）：c0 以下照原样，往上最多到 c0 + room。亮的气雾还是饱和的蓝，不被压成青或白
static float3 sg_soft_cap(float3 c, float c0, float room) {
    float m = max(c.r, max(c.g, c.b));
    if (m <= c0) return c;
    return c * ((c0 + room * (1.0 - exp(-(m - c0) / room))) / m);
}

// MARK: 发送中

/// 气雾（照用户发来的录屏量的）：几层域扭曲的分形噪声，一团团的、略带一点竖的帘子，整片每秒往上飘 0.1 个短边；
/// 上沿在 cloud.x 附近一团团地羽化成黑（羽化宽度按屏高算，Duo 折起和手机一样）；箭头那一带最亮、偏蔚蓝，
/// 往下转靛蓝、再到深紫，箭头上面两边有青和梅紫的色块；亮的地方按最亮的通道一起软压，不往白里溢。
/// 箭头竖杆的尽头往下拖一道淡紫的尾雾（「腾云驾雾」），也是一缕一缕的气雾，越往下越宽越淡
static float3 sg_cloud(float2 px, constant SGUniforms &U, float S, float T) {
    float W = U.size.x, H = U.size.y;
    float ax = U.arrow.x, ay = U.arrow.y;
    float hw = max(U.arrow.z, 1.0);
    float2 q = float2((px.x - 0.5 * W) / S, px.y / S + 0.10 * T);
    float2 w = float2(sg_fbm(q * 1.1 + float2(0.0, 0.03 * T), 3),
                      sg_fbm(q * 1.1 + float2(5.2, 1.3 - 0.02 * T), 3));
    float d1 = sg_fbm(q * 1.8 + 1.2 * (w - 0.5), 3);
    float cu = sg_fbm(float2(q.x * 2.4, q.y * 0.9) + 0.6 * (w - 0.5) + float2(3.3, 7.7), 3);
    float dens = 0.8 * d1 + 0.2 * cu;
    float dn = clamp((dens - 0.50) / 0.12, -2.0, 2.0);

    // 上沿：一团团的、不是圆顶；浓的地方往上多探一点
    float edge = U.cloud.x + 0.045 * H * (2.0 * sg_fbm(float2(q.x * 2.6 + 0.02 * T, 2.0), 2) - 1.0);
    float mask = smoothstep(edge - 0.02 * H, edge + 0.20 * H, px.y + 0.10 * H * (2.0 * dens - 1.0));
    mask = pow(mask, 1.3);
    float k = 1.15 * max(1.0 + 0.45 * dn, 0.0);

    // 箭头那一带（略低于箭头尖）最亮，越靠箭头越亮：箭头「骑」在云上；屏幕最下面淡一点
    float yw = px.y + 0.10 * H * (2.0 * d1 - 1.0);
    float bz = (yw - (ay + 0.02 * H)) / (0.10 * H);
    float band = exp(-bz * bz);
    float cx = (px.x - ax) / (0.45 * S);
    float cen = exp(-cx * cx);
    float env = mix(1.0, 0.40, smoothstep(0.84 * H, H, px.y)) * (1.0 + 0.6 * band * (0.1 + 0.9 * cen)) * (1.0 - 0.1 * (1.0 - cen));

    // 颜色：上沿深蓝 → 靛 → 箭头那一带蔚蓝 → 往下靛蓝 → 最下面深紫；浓的几团偏长春花蓝；青 / 梅紫的色块
    float a1 = sg_fbm(q * 1.2 + float2(11.0, 0.05 * T), 2);
    float a2 = sg_fbm(q * 1.2 + float2(23.0, 4.0 - 0.04 * T), 2);
    float3 tint = mix(kSGNavy, kSGUpper, smoothstep(edge, edge + 0.08 * H, px.y));
    tint = mix(tint, kSGAzure, band * (0.35 + 0.45 * smoothstep(0.35, 0.65, a1)));
    tint = mix(tint, kSGIndigo, smoothstep(ay + 0.04 * H, ay + 0.14 * H, yw));
    tint = mix(tint, kSGDeepViolet, smoothstep(0.80 * H, H, yw));
    tint = mix(tint, kSGPeri, smoothstep(0.8, 1.8, dn) * 0.5);
    float upper = 1.0 - smoothstep(ay - 0.02 * H, ay + 0.06 * H, px.y);
    float an1 = (a1 - 0.51) / 0.115;
    float an2 = (a2 - 0.50) / 0.115;
    tint = mix(tint, kSGTeal, smoothstep(0.9, 1.9, an1) * 0.6 * max(band, 0.25 * upper));
    float side = smoothstep(0.12 * S, 0.32 * S, abs(px.x - ax));
    tint = mix(tint, kSGPlum, smoothstep(0.6, 1.6, an2) * 0.75 * upper * side);

    // 上沿的羽化乘在软压之后：先乘的话亮的地方被压平，0.2 屏高的羽化看着只剩一道硬边（不像录屏里那样慢慢透成黑）
    float3 mist = sg_soft_cap(tint * k, 0.75, 0.30) * (env * mask);
    mist = sg_soft_cap(mist, 0.90, 0.10);

    // 尾雾：从竖杆尽头往下，越往下越宽越淡，几缕竖的；颜色从粉紫过到淡紫
    float sl = 0.5 * hw + 0.11 * S;
    float below = px.y - (ay + 0.9 * sl);
    float wob = 0.02 * S * sin(px.y / H * 7.0 - T * 0.9) * smoothstep(0.0, 0.2 * H, below);
    float pw = 0.06 * S + 0.30 * S * saturate(below / (0.30 * H));
    float u = (px.x - ax - wob) / pw;
    float pil = sg_fbm(float2(u * 0.9, px.y / S * 0.8 + 0.10 * T), 2);
    pil = 0.5 + 0.5 * smoothstep(0.30, 0.70, pil);
    float pl = exp(-u * u) * smoothstep(-0.04 * S, 0.04 * S, below) * (1.0 - 0.55 * smoothstep(0.0, 0.45 * H, below))
             * pil * (0.45 + 0.8 * dens);
    float3 pc = mix(kSGLavHi, kSGLav, smoothstep(-0.02 * S, 0.15 * S, below));
    // 托着箭头的那一团亮雾（录屏里箭头两臂下面一片发亮的云：「骑」在云上），跟着箭头一起淡入淡出
    float2 g = float2((px.x - ax) / (1.15 * hw), (px.y - (ay + 0.30 * hw + 0.04 * H * (2.0 * d1 - 1.0))) / (0.075 * H));
    float cush = exp(-dot(g, g)) * (0.55 + 0.9 * dens) * 0.40 * U.arrow.w;
    float3 gc = mix(kSGPeri, kSGLavHi, 0.35 + 0.3 * smoothstep(0.3, 0.7, a1));
    return mist + pc * (pl * 0.6) + gc * cush;
}

/// 箭头：扁的「^」两条臂 + 一根竖杆，一笔平滑的白芯（没有一颗颗的珠子，两头圆的），外面只有很窄的一点蓝光；
/// 竖杆的尽头一团粉紫的光，接着尾雾往下拖。笔画的宽度跟着箭头一起变小，越往后越柔一点
static float3 sg_arrow(float2 px, constant SGUniforms &U, float S) {
    float2 A = U.arrow.xy;
    float hw = max(U.arrow.z, 1.0);
    float soft = U.cloud.z;
    float sl = 0.5 * hw + 0.11 * S;
    float2 sa = sg_segment(px, A, A + float2(-hw, 0.5 * hw));
    float2 sr = sg_segment(px, A, A + float2(hw, 0.5 * hw));
    float2 sb = sg_segment(px, A, A + float2(0.0, sl));
    float sig = hw * (0.16 + 0.03 * soft);
    float d = min(sa.x, sr.x);
    float ta = d / sig;
    float arms = saturate(1.05 * exp(-ta * ta * ta));
    float tb = sb.x / (sig * (1.3 - 0.2 * sb.y));
    float stem = saturate(1.05 * exp(-tb * tb * tb)) * (1.0 - 0.7 * smoothstep(0.5, 1.0, sb.y));
    float3 scol = mix(kSGCore, kSGLavHi, smoothstep(0.35, 1.0, sb.y));
    float3 core = max(kSGCore * (arms * 0.97), scol * (stem * 0.95));
    float halo = (0.6 * exp(-d / (0.16 * hw)) + 0.6 * exp(-(d * d) / (0.09 * hw * hw)))
               * (1.0 - 0.6 * smoothstep(-0.1 * hw, 0.6 * hw, px.y - A.y));
    float2 du = float2((px.x - A.x) / (0.04 * S), (px.y - (A.y + 0.85 * sl)) / (0.06 * S));
    float under = exp(-dot(du, du));
    float3 glow = kSGHalo * (halo * 0.05) + kSGLavHi * (under * 0.6);
    return core + glow * (1.0 - core);
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

    // 底色：近黑，结果那一组周围再暗一点（字最清楚）；发送中再压暗六成，气雾外面是纯黑的天（录屏里那样），气雾收掉就回到原来的底色
    float3 base = kSGInk * (1.0 - 0.5 * exp(-(fr * fr) / (0.2025 * S * S)));
    base *= 1.0 - 0.6 * saturate(U.cloud.y);
    float3 light = float3(0.0);
    float3 send = float3(0.0);

    // 闲置：底边一点很淡的青紫光（胶囊那儿）
    if (U.cloud.w > 0.001) {
        float e = max(-sd, 0.0);
        float g = exp(-e / (0.05 * S)) * smoothstep(0.55 * H, H, px.y);
        light += mix(kSGCyan, kSGViolet, smoothstep(0.2 * W, 0.8 * W, px.x)) * g * 0.35 * U.cloud.w;
    }

    // 发送中：气雾（上沿再往上 0.16 屏高、又在箭头尖上面的地方一定是黑的，不算噪声），箭头按「滤色」叠在气雾上（不相加，不爆白）
    if (U.cloud.y > 0.001 && px.y > min(U.cloud.x - 0.16 * H, U.arrow.y)) send += sg_cloud(px, U, S, T) * U.cloud.y;
    if (U.arrow.w > 0.001) {
        float3 a = sg_arrow(px, U, S) * U.arrow.w;
        send += a * (1.0 - saturate(send));
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
    // 之后慢慢从紫往青漂，左右两边颜色不一样（参照录屏 5.6、7.0 秒）。
    // 亮边按圆角矩形的有向距离 sd 量（不是横竖两条边各量一份再加起来）：圆角那一段和直边一样宽、贴着屏幕的圆角走，角上不叠成两份；
    // 往里的羽化和远一点的光晕按 sg_edge_soft 量：深处也是圆角，不在四个角折出斜缝（用户 iPhone Duo 截图：光的圆角不跟屏幕的角）
    if (U.edge.x > 0.001) {
        float e = max(-sd, 0.0);
        if (e < 0.5 * S) {
            float rimW = 0.03 * S;
            float es = max(sg_edge_soft(px - mid, mid, max(1.17 * U.size.z, 0.15 * S)), 0.0);
            float rim = exp(-(e * e) / (rimW * rimW));
            float feather = exp(-es / (rimW * 3.0));
            float haze = exp(-es / (0.20 * S));
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
            float3 el = (rcol * rim * 1.15 + fcol * feather * 0.55 + fcol * haze * 0.10) * U.edge.x * arrive * boost * breathe;
            // 封顶（色相不变，按最亮的那个通道一起压，0.7 以上软压、最多到 1.1）：不封的话亮边叠到 1.8 左右，sg_tone 把它往白里溢，
            // 整圈是死白，圆角那一段看着就是「爆白」（用户 iPhone Duo 截图）。现在边上是淡紫 / 淡青的亮线，只带一丝白；
            // 软压不硬截，亮边往里是一路渐暗的，不是一条平平的色带
            float em = max(el.r, max(el.g, el.b));
            float ek = em < 0.7 ? em : 0.7 + 0.4 * (1.0 - exp(-(em - 0.7) / 0.4));
            light += el * (ek / max(em, 1.0e-4));
        }
    }

    // 环、闪光、边缘光照旧走 sg_tone；发送的光走 sg_knee（不溢白），两者按滤色合在一起（重叠的那几帧也不会超过 1）
    float3 lt = sg_tone(light);
    float3 c = base + lt + sg_knee(send) * (1.0 - lt);
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
