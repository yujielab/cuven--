#include <metal_stdlib>
using namespace metal;

// 详情页字标的粒子转场（用户要求，照用户给的动效说明和参考录屏）：往下滚，头部的大字标化成细粒子，沿一条先往右鼓、
// 再弯进左上角的弧线飞上去，在顶上条里拼回小字标（大字标宽的 42%）；往回滚原路倒回去。
// 整个画面只看滚动进度（LPUniforms.view.w），没有时钟：停在哪一帧就是哪一帧，倒着滚就是倒着放。
// 字标切成一格一格（大字标上约 2.4 点一格），每格两个门槛：离开大字标的进度（右下先走，0–0.62）、落进小字标的进度
// （中间那一条主字标先到 0.65–0.80，上面的厂牌、下面的副标题随后，最晚 0.90）。一帧三样东西：
//   1. 大字标（这一帧的框）上还没走的格子；2. 小字标上已经落定的格子；3. 正在路上的格子：每格一到三粒，颜色取这一格的平均色，
//      画成一颗软的小点，顺着速度拖一截很短、越往后越淡的尾巴。两枚字标底下还有和 LogoImage 一样的影子。
// 颜色都是预乘 alpha 的 Display P3，空间和画布一致：能显示 HDR 的屏上是线性的扩展 Display P3（和字标管线 LogoHDR 一致，
// 亮部照样比 SDR 白亮）；SDR 屏上是编码过的（8 位画布、贴图都不带 _srgb），和 SwiftUI / Core Animation 画真字标一样
// 在编码空间里预乘、叠加，半透明的边和粒子的软边不会比真字标亮一圈。着色器里不用分两种情况，只有提亮的幅度看 LPUniforms.tone。
// 所有函数名带 lp_ 前缀。

#define LP_PI 3.14159265

struct LPUniforms {
    float4 view;     // x 画布宽（像素），y 高，z 一点是几像素，w 进度（0…1）
    float4 src;      // 大字标这一帧的框（像素，x y 宽 高；已经按进度缩过）
    float4 dst;      // 小字标的框（像素）
    float4 grid;     // x 列数，y 行数，z 格子和粒子交接的那一小段（进度），w 尾巴有多长（进度）
    float4 path;     // x 往右鼓多少（像素），y 中段收窄（0…1），z 横向抖动（像素），w 摆动（像素）
    float4 anchor;   // xy 光流的起点（像素，跟着溶解的前沿往左挪），zw 终点（小字标里偏右一点）
    float4 extra;    // x 尾巴最长（像素），y 刚离开时散开多少（像素），z 快落定时收拢前散开多少（像素），w 弧线高度至少多少（像素）
    float4 tone;     // x 路上提亮多少，y 闪一下提亮多少，z 颜色上限（SDR 是 1：预乘的颜色不超过 alpha），w 不用
};

struct LPQuad {
    float4 rect;     // 字标的框（像素）
    float4 info;     // x 往外多画几像素（影子），y 哪一枚（0 大字标，1 小字标），z 影子取哪一级 mip，w 不用
    float4 shadow;   // x 影子往下偏（uv 的 y），y 模糊步长（uv 的 x），z 模糊步长（uv 的 y），w 影子不透明度
};

struct LPParticle {
    float4 cell;     // xy 在字标上的位置（0…1，y 向下），z 离开大字标的进度，w 落进小字标的进度
    float4 color;    // rgb 这一格的平均色（和画布同一个空间、去掉预乘），a 不透明度
    float4 seed;     // x 横向抖动，y 摆动的相位，z 散开的方向，w 散开的幅度（都是 0…1）
    float4 shape;    // x 直径（点），y 比同一格的领头那粒落后多少，z 闪烁的种子，w 不用
};

// MARK: - 共用

static float lp_hash(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

static float4 lp_ndc(float2 px, constant LPUniforms &U) {
    return float4(px.x / U.view.x * 2.0 - 1.0, 1.0 - px.y / U.view.y * 2.0, 0.0, 1.0);
}

/// 这一点所在的格子这一帧看得见几成：大字标上离开以前是 1，离开后很短一段里淡掉（同一处的粒子同时淡入）；
/// 小字标上快落定时淡入（同一处的粒子同时淡出）。交接得很短，看起来就是粒子从这一格里飞出去、又嵌回那一格
static float lp_visible(const device float2 *cells, constant LPUniforms &U, float2 uv, float which) {
    int cols = max(int(U.grid.x), 1), rows = max(int(U.grid.y), 1);
    int cx = clamp(int(uv.x * U.grid.x), 0, cols - 1);
    int cy = clamp(int(uv.y * U.grid.y), 0, rows - 1);
    float2 th = cells[cy * cols + cx];
    float p = U.view.w, w = U.grid.z;
    return which < 0.5 ? 1.0 - smoothstep(th.x, th.x + w, p) : smoothstep(th.y - w, th.y, p);
}

// MARK: - 两枚字标（按格子遮住的贴图）和它们的影子

struct LPQuadOut {
    float4 pos [[position]];
    float2 uv;   // 字标上的 uv（影子那一块往外多画了一圈，会超出 0…1）
};

vertex LPQuadOut lp_quad_vertex(uint vid [[vertex_id]],
                                constant LPUniforms &U [[buffer(0)]],
                                constant LPQuad &Q [[buffer(1)]]) {
    float2 corner = float2(float(vid & 1u), float(vid >> 1u));
    float pad = Q.info.x;
    float2 px = Q.rect.xy - pad + corner * (Q.rect.zw + 2.0 * pad);
    LPQuadOut o;
    o.pos = lp_ndc(px, U);
    o.uv = (px - Q.rect.xy) / max(Q.rect.zw, float2(1.0e-3));
    return o;
}

fragment float4 lp_logo_fragment(LPQuadOut in [[stage_in]],
                                 constant LPUniforms &U [[buffer(0)]],
                                 constant LPQuad &Q [[buffer(1)]],
                                 const device float2 *cells [[buffer(2)]],
                                 texture2d<float> logo [[texture(0)]]) {
    float2 uv = in.uv;
    if (any(uv < float2(0.0)) || any(uv > float2(1.0))) discard_fragment();
    float k = lp_visible(cells, U, uv, Q.info.y);
    if (k <= 0.0) discard_fragment();
    // 小字标只有大字标四成多宽：靠 mip 缩小，边缘不闪、不起锯齿（和系统画缩小的图一样平滑）
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    return logo.sample(s, uv) * k;
}

/// 影子：和 LogoImage 的 .shadow(黑 55%、半径 12、往下 4 点) 对得上，不然真字标一藏起来影子就突然没了。
/// 在模糊过的那一级 mip 上取 3×3 个点（1-2-1 权重）近似高斯；已经飞走 / 还没落定的地方影子跟着淡
fragment float4 lp_shadow_fragment(LPQuadOut in [[stage_in]],
                                   constant LPUniforms &U [[buffer(0)]],
                                   constant LPQuad &Q [[buffer(1)]],
                                   const device float2 *cells [[buffer(2)]],
                                   texture2d<float> logo [[texture(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_zero);
    float2 uv = in.uv - float2(0.0, Q.shadow.x);
    float2 r = Q.shadow.yz;
    float lod = Q.info.z;
    float a = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float w = (i == 0 ? 2.0 : 1.0) * (j == 0 ? 2.0 : 1.0);
            a += logo.sample(s, uv + float2(float(i), float(j)) * r, level(lod)).a * w;
        }
    }
    a *= 1.0 / 16.0;
    if (a <= 0.001) discard_fragment();
    float2 m = saturate(uv);
    float which = Q.info.y;
    float k = 2.0 * lp_visible(cells, U, m, which)
            + lp_visible(cells, U, saturate(m + float2(r.x, 0.0)), which)
            + lp_visible(cells, U, saturate(m - float2(r.x, 0.0)), which)
            + lp_visible(cells, U, saturate(m + float2(0.0, r.y)), which)
            + lp_visible(cells, U, saturate(m - float2(0.0, r.y)), which);
    k *= 1.0 / 6.0;
    float alpha = saturate(a * Q.shadow.w * k);
    return float4(0.0, 0.0, 0.0, alpha);
}

// MARK: - 路上的粒子

/// 0…1 的路程：先慢后快再慢（离开时像从字标上剥下来，落定前减速嵌回去）；lag 越大，中途越落在领头那粒后面，两头还是同时
static float lp_ease(float t, float lag) {
    t = saturate(t);
    float e = t * t * (3.0 - 2.0 * t);
    return pow(max(e, 1.0e-6), 1.0 + lag);
}

/// 走到 s（0…1）时在画布上的哪儿（像素）。一条三次贝塞尔当中线：从溶解前沿出发，先往右上鼓出去，再从右边弯进左上角的小字标；
/// 每粒相对中线的偏移从「它在大字标上的位置」慢慢变成「它在小字标上的位置」，中段收得很窄（一条细的光流）；
/// 再加一点横向抖动、摆动，刚离开时往四周散开一点（字标边上一片碎光），快落定时也散一点再收拢
static float2 lp_path(LPParticle P, float s, constant LPUniforms &U) {
    float2 uv = P.cell.xy;
    float2 cs = U.src.xy + uv * U.src.zw;
    float2 cd = U.dst.xy + uv * U.dst.zw;
    float2 sa = U.anchor.xy, da = U.anchor.zw;
    float dy = max(abs(da.y - sa.y), U.extra.w);
    float2 c1 = sa + float2(U.path.x, -0.42 * dy);
    float2 c2 = float2(da.x + 0.9 * U.path.x, da.y + 0.22 * dy);
    float m = 1.0 - s;
    float2 b = m * m * m * sa + 3.0 * m * m * s * c1 + 3.0 * m * s * s * c2 + s * s * s * da;
    float2 tg = 3.0 * m * m * (c1 - sa) + 6.0 * m * s * (c2 - c1) + 3.0 * s * s * (da - c2);
    float tl = length(tg);
    float2 nrm = tl > 1.0e-3 ? float2(-tg.y, tg.x) / tl : float2(1.0, 0.0);
    float2 off = (cs - sa) * m + (cd - da) * s;
    float env = sin(LP_PI * saturate(s));
    float squeeze = 1.0 - U.path.y * sqrt(env);
    float jit = (P.seed.x * 2.0 - 1.0) * U.path.z * pow(max(env, 1.0e-6), 0.8)
              + U.path.w * env * sin(2.0 * LP_PI * (1.5 * s + P.seed.y));
    float ang = P.seed.z * 2.0 * LP_PI;
    float amp = 0.5 + 0.5 * P.seed.w;
    float m2 = m * m;
    float burst = s * m2 * m2 * 12.2 * U.extra.y * amp;              // s(1-s)^4：s = 0.2 时最大
    float gather = s * s * s * s * m * 12.2 * U.extra.z * amp;       // s^4(1-s)：s = 0.8 时最大
    return b + off * squeeze + nrm * jit + float2(cos(ang), sin(ang)) * (burst + gather);
}

struct LPDotOut {
    float4 pos [[position]];
    float2 local;   // 像素：x 从尾巴（0）往头（len），y 横向
    float4 color;   // 预乘过的
    float len;      // 尾巴多长（像素）
    float rad;      // 点的半径（像素）
};

vertex LPDotOut lp_dot_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device LPParticle *ps [[buffer(0)]],
                              constant LPUniforms &U [[buffer(1)]]) {
    LPParticle P = ps[iid];
    LPDotOut o;
    o.local = float2(0.0);
    o.color = float4(0.0);
    o.len = 0.0;
    o.rad = 1.0;
    float p = U.view.w;
    float d = P.cell.z, a = P.cell.w;
    if (!(p > d && p < a)) {
        o.pos = float4(2.0, 2.0, 2.0, 1.0);   // 不在路上：画面外的退化四边形
        return o;
    }
    float span = max(a - d, 1.0e-3);
    float t = (p - d) / span;
    float s = lp_ease(t, P.shape.y);
    float st = lp_ease(t - U.grid.w / span, P.shape.y);
    float2 head = lp_path(P, s, U);
    float2 tail = lp_path(P, st, U);
    float2 seg = head - tail;
    float len = length(seg);
    float maxLen = U.extra.x;
    if (len > maxLen) {
        tail = head - seg * (maxLen / len);
        len = maxLen;
    }
    float2 dir = len > 1.0e-3 ? seg / len : float2(1.0, 0.0);
    float2 nr = float2(-dir.y, dir.x);
    float env = sin(LP_PI * s);
    // 1–2 点的细粒子，往小字标走时跟着变小一点；最小一个像素，不会闪
    float rad = max(P.shape.x * 0.5 * U.view.z * (1.0 - 0.3 * s) * (1.0 + 0.15 * env), 0.6);
    float R = rad + 1.0;
    float side = (vid & 1u) ? 1.0 : -1.0;
    bool atHead = vid >= 2u;
    float2 base = atHead ? head + dir * R : tail - dir * R;
    o.pos = lp_ndc(base + nr * side * R, U);
    o.local = float2(atHead ? len + R : -R, side * R);
    o.len = len;
    o.rad = rad;
    // 颜色：这一格的平均色，路上稍微亮一点；少数几粒（约 7%）路过时闪一下（按路程，不按时间：停住就停在那一下）。
    // 闪只提亮、不掺白：颜色都是从字标上取的（用户要求红、蓝的细粒子夹几粒黄，不能冒出粉白、淡紫的）
    float3 c = P.color.rgb * (1.0 + U.tone.x * env);
    float sparkle = step(0.93, lp_hash(P.shape.z * 97.0 + floor(s * 16.0))) * env;
    c *= 1.0 + U.tone.y * sparkle;
    c = min(c, float3(U.tone.z));
    float fadeIn = smoothstep(d, d + U.grid.z, p);
    float fadeOut = 1.0 - smoothstep(a - U.grid.z, a, p);
    float alpha = saturate(P.color.a) * fadeIn * fadeOut;
    o.color = float4(c * alpha, alpha);
    return o;
}

/// 一颗软的小点，后面拖一截越来越细、越来越淡的尾巴
fragment float4 lp_dot_fragment(LPDotOut in [[stage_in]]) {
    float x = in.local.x, y = in.local.y;
    // 头：一颗完整的软圆点（走得慢、尾巴很短时也是圆的）
    float dh = length(float2(x - in.len, y));
    float head = 1.0 - smoothstep(in.rad * 0.5, in.rad + 0.75, dh);
    // 尾巴：从头往后越来越细、越来越淡，到尾端没了
    float along = in.len > 1.0e-3 ? saturate(x / in.len) : 0.0;
    float cx = clamp(x, 0.0, in.len);
    float dist = length(float2(x - cx, y));
    float rr = in.rad * mix(0.4, 0.9, along);
    float trail = (1.0 - smoothstep(rr * 0.5, rr + 0.75, dist)) * along * along * 0.8;
    float k = max(head, trail);
    if (k <= 0.002) discard_fragment();
    return in.color * k;
}
