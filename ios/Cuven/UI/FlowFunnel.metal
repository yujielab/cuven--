#include <metal_stdlib>
using namespace metal;

// 请求中心最上面那张「Luminous Data Flow」卡里的漏斗（用户要求：影片进入传输时有动画，参照用户发来的录屏和设计说明）。
// 一整块连续的发光「薄膜」：上下两条边是同一条连续曲线（每一段的高度跟这一段的数量成正比，段与段之间是平滑的 S 形收口，
// 没有一块块的梯形），中间一条水平中轴；里面是一格格细小的方点阵，点阵上一粒粒光点从左往右流（光点在「相对中轴的位置」里排成一条条道，
// 漏斗收窄时自然往中轴挤）；传输进行中，一团集中的光从左边聚起来、横着穿过整片点阵（经过的点变亮发白、边线跟着亮一点），到最右边慢慢淡掉。
// 颜色是一条从左到右的渐变（分类不同颜色不同，切换时整体平滑过渡）；边线是一条很细的亮线，里面一层淡的内光，外面一圈很克制的辉光。
// 只有一遍全屏的片元着色器：几何、点阵、光点、能量波、辉光都按像素算出来，跟数据用同一份插值后的状态（FlowFunnelEngine）。

struct FFUniforms {
    float4 size;      // x 宽（像素），y 高，z 一格点阵多大（像素），w 一点（pt）是几像素
    float4 heights;   // 四段的半高（0…1，1 = 最大半高）
    float4 c0;        // 左边的颜色（rgb）
    float4 c1;        // 右边的颜色（rgb）
    float4 wave;      // x 能量波在哪儿（0…1，可以在两头外面），y 强度（0…1），z 时间（秒），w 光点流速倍数
    float4 extra;     // x 整体亮度（0…1，出现 / 消失），y 减弱动态效果（1 = 是），z 底色亮度（没用了：底是透明的），w 进度（0…1，最后一段里那一截更亮）
    float4 layout;    // x 主体左右各缩进多少像素（四段对着上面那一行数），y 上下给辉光留多少像素，z 左右淡出多宽（像素）
};

struct FFOut {
    float4 pos [[position]];
    float2 uv;
};

vertex FFOut ff_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FFOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

static float ff_hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float ff_hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

/// 平滑的 S 形（三次 ease-in-out），收口用
static float ff_ease(float a, float b, float x) {
    float t = saturate((x - a) / (b - a));
    return t < 0.5 ? 4.0 * t * t * t : 1.0 - pow(-2.0 * t + 2.0, 3.0) * 0.5;
}

/// x 处的半高（0…1）：第 i 段从自己的高度在这一段的 28%–64% 之间平滑收到下一段的高度；最后一段一直平到头
static float ff_half(float x, float4 H) {
    float f = clamp(x, 0.0, 0.9999) * 4.0;
    int i = int(floor(f));
    float u = f - float(i);
    float a = H[i];
    float b = i < 3 ? H[i + 1] : H[3];
    return mix(a, b, ff_ease(0.28, 0.64, u));
}

fragment float4 ff_fragment(FFOut in [[stage_in]], constant FFUniforms &U [[buffer(0)]]) {
    float W = U.size.x, Hpx = U.size.y, cell = U.size.z, pt = U.size.w;
    float2 px = in.uv * float2(W, Hpx);
    float t = U.wave.z;
    float reduce = U.extra.y;
    // 画布比主体宽、比主体高（用户要求「允许光效溢出，拉长主体不用留间隙」）：左右一直铺到卡边，主体在两头接着往外伸
    // （左边按第一段的高、右边按最后一段的高），到卡边淡掉；上下多出来的那一截只给辉光
    float inset = U.layout.x, spill = U.layout.y, fadePx = max(U.layout.z, 1.0);
    float bodyW = max(W - 2.0 * inset, 1.0);

    // 坐标：x 0…1（主体的左 → 右，两头外面是 <0 / >1），y 以中轴为 0，±1 = 最大半高（上下各留一点给外面的辉光）
    float maxHalf = (Hpx - 2.0 * spill) * 0.5 - 7.0 * pt;
    float x = (px.x - inset) / bodyW;
    float yPx = px.y - Hpx * 0.5;
    float h = ff_half(x, U.heights);
    float hPx = max(h * maxHalf, 1.0);
    // 到边线的距离（像素，按斜率修正，斜坡上的线也一样细）；负的是在里面
    float eps = 1.5 / bodyW;
    float slope = (ff_half(x + eps, U.heights) - ff_half(x - eps, U.heights)) * maxHalf / (2.0 * eps * bodyW);
    float d = (abs(yPx) - hPx) / sqrt(1.0 + slope * slope);

    // 一条从左到右的渐变：边线、内光、光点、辉光都用它
    float3 col = mix(U.c0.rgb, U.c1.rgb, smoothstep(0.0, 1.0, x));

    // 能量波：一团集中的光横着穿过去，前后都是柔和的衰减；左边起步时先聚一下，到右边慢慢淡掉
    float wx = U.wave.x;
    float wI = U.wave.y * (1.0 - reduce * 0.7);
    float wave = exp(-pow((x - wx) / 0.055, 2.0)) * wI * smoothstep(-0.1, 0.06, wx) * (1.0 - 0.55 * smoothstep(0.6, 1.08, wx));

    // 左右两头没有边界（用户要求「粒子没有边界，靠近左右边缘时使用模糊淡出，不希望看到明显的边界」）：
    // blur：离左右边缘越近越虚（0 = 中间，1 = 贴着边），点阵变大变软、边线和辉光变宽变软；
    // fade：最外 11% 宽里亮度平滑地降到 0，正好落在卡的底色上
    // 按离画布左右两边（卡边）多远算：主体伸出去的那一截里虚化、淡掉
    float edgePx = min(px.x, W - px.x);
    float blur = 1.0 - smoothstep(0.0, fadePx * 1.45, edgePx);
    float fade = smoothstep(0.0, fadePx, edgePx);
    fade = fade * fade * (3.0 - 2.0 * fade);

    float3 c = float3(0.0);
    float soft = 0.5 + 3.0 * blur * pt;
    float inside = 1.0 - smoothstep(-soft, soft, d);

    if (d < soft) {
        // 内光：薄膜里一层淡淡的同色光，靠边线的地方亮一点，越往右越淡一点
        float v = yPx / hPx;                                    // -1…1：相对中轴的位置
        float edge = smoothstep(0.55, 1.0, abs(v));
        float3 fill = col * (0.085 + 0.07 * edge + 0.05 * (1.0 - saturate(x))) * (1.0 + 1.2 * wave);

        // 点阵：一格一格的小方点（屏幕上对齐，像一块点阵屏）；每一格先有一个很暗的底点
        float2 g = px / cell;
        float2 cid = floor(g);
        float2 cc = (cid + 0.5) * cell;                         // 这一格的中心
        float2 lp = fract(g) - 0.5;
        float sq = max(abs(lp.x), abs(lp.y));
        // 靠近左右边缘：点的边越来越软、往外散开一点（虚焦），亮度不变多少，交给下面的 fade 淡掉
        float dotMask = 1.0 - smoothstep(0.24 - 0.12 * blur, 0.24 + 1.2 / cell + 0.3 * blur, sq);
        // 格子中心那一点在不在漏斗里（不在的不画，边上不会冒出半个点）
        float xc = (cc.x - inset) / bodyW;
        float hc = max(ff_half(xc, U.heights) * maxHalf, 1.0);
        float vc = (cc.y - Hpx * 0.5) / hc;
        float inCell = step(abs(vc), 0.97);

        // 光点：按「相对中轴的位置」分成 28 条道，每条道上的光点各自从左往右流（速度、密度、亮度都有一点不一样）；
        // 道是按相对位置分的，漏斗收窄时同样的道挤进更少的行，看起来就是往中轴收
        float lanes = 28.0;
        float lane = floor((clamp(vc, -0.999, 0.999) * 0.5 + 0.5) * lanes);
        float spd = (0.045 + 0.055 * ff_hash11(lane * 7.13 + 1.7)) * U.wave.w * (1.0 - 0.75 * reduce);
        float slots = bodyW / cell;
        float q = xc * slots - t * spd * slots;
        float slot = floor(q);
        float occ = step(0.86 - 0.08 * (1.0 - saturate(x)), ff_hash21(float2(lane * 3.1 + 0.7, slot)));
        float twinkle = 0.55 + 0.45 * ff_hash21(float2(slot * 1.7, floor(t * 6.0) + lane));
        float bright = occ * (0.35 + 0.65 * ff_hash21(float2(slot, lane * 5.3))) * twinkle;
        // 一格里的光点跟着走：刚进这一格亮、快离开时暗一点，不是一格一格硬跳
        bright *= 0.6 + 0.4 * (1.0 - fract(q));

        float base = 0.10 + 0.06 * ff_hash21(cid * 0.37);
        float3 dotCol = mix(col, float3(1.0), 0.25 + 0.55 * wave) * (base + 1.15 * bright + 1.6 * wave * (0.45 + 0.55 * ff_hash21(cid + floor(t * 10.0))));
        float3 dots = dotCol * dotMask * inCell;

        // 段与段之间的分隔线：细细的一条竖线（只在漏斗里面）
        float sep = 0.0;
        for (int k = 1; k < 4; k++) {
            float sx = inset + float(k) * 0.25 * bodyW;
            sep += (1.0 - smoothstep(0.0, 1.0 * pt, abs(px.x - sx)));
        }
        float3 sepCol = mix(col, float3(1.0), 0.6) * sep * 0.55;

        // 最后一段里，传输进度那一截更亮一点（和下面的进度条是同一个数）
        float lastU = saturate((x - 0.75) / 0.25);
        float prog = step(lastU, U.extra.w) * step(0.75, x) * 0.08;

        c += (fill + dots + sepCol + col * prog) * inside;
    }

    // 边线：一条很细、很亮的线（中间偏白），外面一层窄的辉光、一层很淡的宽辉光；能量波经过时边线也跟着亮一点
    // 靠近左右边缘：线变宽变软（虚焦），总亮度大致不变
    float ad = abs(d);
    float spread = 1.0 + 3.0 * blur;
    float core = 1.0 - smoothstep(0.35 * pt * spread, 1.1 * pt * spread, ad);
    float glowN = exp(-max(d, 0.0) / (3.5 * pt * spread)) * step(0.0, d);
    float glowW = exp(-max(d, 0.0) / (16.0 * pt)) * step(0.0, d);
    float lit = 1.0 + 0.9 * wave;
    c += mix(col, float3(1.0), 0.35) * core * 1.25 * lit / spread;
    c += col * (glowN * 0.32 + glowW * 0.07) * lit;

    // 从每一段的起点往上下各拉一条很淡的虚线（连到上面那一行数字）
    for (int k = 0; k < 4; k++) {
        float sx = inset + (float(k) * 0.25) * bodyW + (k == 0 ? 1.5 * pt : 0.0);
        float vline = (1.0 - smoothstep(0.0, 0.8 * pt, abs(px.x - sx))) * step(0.0, d);
        float dash = step(0.5, fract(px.y / (4.0 * pt)));
        c += float3(1.0) * vline * dash * 0.05;
    }

    c *= U.extra.x * fade;
    // 柔和的色调映射（亮的地方不会一片死白）；底是透明的（预乘 alpha）：画布可以盖过卡边、数那一行，下面的卡照样透出来
    float3 mapped = 1.0 - exp(-c * 1.15);
    float a = saturate(max(mapped.r, max(mapped.g, mapped.b)));
    return float4(mapped, a);
}
