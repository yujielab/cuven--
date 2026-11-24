#include <metal_stdlib>
using namespace metal;

// 清除缓存的动画「Prismatic Data Dissolution」（用户要求，参照他发来的录屏）：
// 一张浮在黑底上的 3D 存储卡从下沿开始化成一片闪烁的「数据」光点 → 每个光点沿一条引导路径落向进度胶囊的正中：
// 竖直方向先慢后快，横向绕着胶囊那根竖轴边拧边收（龙卷风那样），中段带一点旋度噪声的扰动 —— 同一缕的光点走同一条路，
// 连成一根根细光纤，最后全都收进按钮那一点（用户要求「粒子最终汇聚在按钮位置」）→ 那一点是一团横向的柔光，两边几颗彩色光斑，
// 四周泛起青蓝 / 暖紫的环境光 → 流变细、光收掉。
// 一帧：粒子更新（计算）→ 卡（带深度）→ 粒子拉成细线（相加混合）→ 拖尾累积（上一帧往下、往中轴挪一点再衰减）→
// 亮部降采样 + 两档高斯模糊（辉光）→ 合成（侧向色散、光源、环境光、ACES 映射）。所有函数名带 cd_ 前缀。

struct CDUniforms {
    float4x4 viewProj;
    float4x4 cardModel;
    float4 camera;        // xyz 相机位置，w 收尾的那一下（0…1：按钮那儿往上散开的光束、一地彩色光斑）
    float4 timing;        // x 时间，y 这一帧的 dt，z 溶解前沿（卡面 v，0 = 下沿），w 光流整体亮度上限（收尾时降到 0）
    float4 target;        // xyz 汇聚点（世界坐标），w 吸收半径
    float4 screen;        // x 宽（像素），y 高，z 光纤线宽（像素），w 光源强度 0…1
    float4 params;        // x 落下来要多久（秒），y 一路拧几弧度，z 横向摆动幅度，w 粒子数
    float4 targetScreen;  // xy 汇聚点在画面上（uv，y 向下），z 宽高比，w 时间
    float4 cardInfo;      // x 半宽，y 半高，z 半厚，w 是否减弱动态效果（1 = 不放粒子）
    float4 trail;         // x 这一帧的拖尾保留比例，y 色散强度，z 环境光强度，w 卡的整体淡出（0…1）
};

struct CDParticle {
    float4 pos;   // xyz 世界坐标；w < 0 还在卡上，w ≥ 0 脱落后过了多久，w ≥ 1e4 已经被吸收
    float4 vel;   // xyz 速度（这一帧走了多少 / dt，拉线用）；w 亮度
    float4 home;  // xy 在卡面上的 uv（v 从下往上），z 随机种子，w 属于哪一缕（0…1）
    float4 orig;  // xyz 脱落的那一点（世界坐标），w 落到按钮要多久（秒）
};

struct CDCardVertex {
    float4 pos;   // xyz 卡的局部坐标，w 哪一面（0 正面，1 背面，2 侧边）
    float4 nrm;
    float4 uv;    // xy 贴图坐标，z 卡面 v（0 下沿 … 1 上沿），w 卡面 u
};

// MARK: 噪声

static float cd_hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float cd_hash31(float3 p3) {
    p3 = fract(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}

static float cd_hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

static float cd_noise2(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = cd_hash21(i), b = cd_hash21(i + float2(1, 0));
    float c = cd_hash21(i + float2(0, 1)), d = cd_hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float cd_noise3(float3 p) {
    float3 i = floor(p), f = fract(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float n000 = cd_hash31(i);
    float n100 = cd_hash31(i + float3(1, 0, 0));
    float n010 = cd_hash31(i + float3(0, 1, 0));
    float n110 = cd_hash31(i + float3(1, 1, 0));
    float n001 = cd_hash31(i + float3(0, 0, 1));
    float n101 = cd_hash31(i + float3(1, 0, 1));
    float n011 = cd_hash31(i + float3(0, 1, 1));
    float n111 = cd_hash31(i + float3(1, 1, 1));
    float x00 = mix(n000, n100, u.x), x10 = mix(n010, n110, u.x);
    float x01 = mix(n001, n101, u.x), x11 = mix(n011, n111, u.x);
    return mix(mix(x00, x10, u.y), mix(x01, x11, u.y), u.z);
}

static float3 cd_potential(float3 p) {
    return float3(cd_noise3(p), cd_noise3(p + float3(31.4, 17.2, 5.9)), cd_noise3(p + float3(-12.7, 44.1, 23.3)));
}

/// 旋度噪声：无散的流场（光点不会聚成团、也不会凭空散开，像液体）
static float3 cd_curl(float3 p) {
    const float e = 0.12;
    float3 dx = float3(e, 0, 0), dy = float3(0, e, 0), dz = float3(0, 0, e);
    float3 px0 = cd_potential(p - dx), px1 = cd_potential(p + dx);
    float3 py0 = cd_potential(p - dy), py1 = cd_potential(p + dy);
    float3 pz0 = cd_potential(p - dz), pz1 = cd_potential(p + dz);
    float x = (py1.z - py0.z) - (pz1.y - pz0.y);
    float y = (pz1.x - pz0.x) - (px1.z - px0.z);
    float z = (px1.y - px0.y) - (py1.x - py0.x);
    return float3(x, y, z) / (2.0 * e);
}

/// 光谱色（很淡地用：白芯上的彩边）
static float3 cd_spectral(float t) {
    return saturate(0.5 + 0.5 * cos(6.2831853 * (t + float3(0.0, 0.33, 0.67))));
}

/// 卡面上溶解前沿的锯齿：卡的着色器和粒子脱落用同一个，粒子正好在卡面消失的那一刻脱落
static float cd_jag(float2 uv) {
    return (cd_noise2(uv * float2(9.0, 5.0) + 3.1) - 0.5) * 0.09 + (cd_noise2(uv * float2(41.0, 23.0)) - 0.5) * 0.025;
}

// MARK: 粒子更新

kernel void cd_update(device CDParticle *ps [[buffer(0)]],
                      constant CDUniforms &U [[buffer(1)]],
                      uint id [[thread_position_in_grid]]) {
    if (id >= uint(U.params.w)) return;
    CDParticle p = ps[id];
    float t = U.timing.x, dt = U.timing.y, front = U.timing.z;
    float3 local = float3((p.home.x * 2.0 - 1.0) * U.cardInfo.x, (p.home.y * 2.0 - 1.0) * U.cardInfo.y, U.cardInfo.z * 1.02);
    float3 onCard = (U.cardModel * float4(local, 1.0)).xyz;

    if (p.pos.w < 0.0) {
        // 还在卡上：跟着卡走；前沿扫过就脱落，记下脱落点和这一路要走多久（同一缕差不多，缕与缕之间有快有慢）
        if (U.cardInfo.w < 0.5 && p.home.y + cd_jag(p.home.xy) < front) {
            float strand = cd_hash11(p.home.w * 91.7);
            float dur = U.params.x * (0.82 + 0.36 * strand + 0.10 * cd_hash11(p.home.z * 7.3));
            p.orig = float4(onCard, dur);
            p.pos = float4(onCard, 0.0);
            p.vel = float4(0.0, 0.0, 0.0, 1.0);
        } else {
            p.pos.xyz = onCard;
        }
        ps[id] = p;
        return;
    }
    if (p.pos.w >= 1.0e4) return;

    float age = p.pos.w + dt;
    float s = saturate(age / max(p.orig.w, 0.1));
    float3 P0 = p.orig.xyz, T = U.target.xyz;
    // 竖直：先慢（在卡下沿闪一下、聚成一片碎光），再越落越快；k = 落了几成
    float k = pow(s, 1.35);
    float y = mix(P0.y, T.y, k);
    // 横向：整束光像一只倒过来的花瓶 —— 上半截差不多跟卡一样宽，往下才收，到按钮那一点收成一个尖（参照录屏）；
    // 一边收一边绕着按钮那根竖轴轻轻拧一点
    float2 L0 = P0.xz - T.xz;
    float shrink = pow(1.0 - k, 0.55);
    float ang = k * U.params.y * (0.6 + 0.8 * cd_hash11(p.home.w * 17.3) - 0.3);
    float ca = cos(ang), sa = sin(ang);
    float2 L = float2(L0.x * ca - L0.y * sa, L0.x * sa + L0.y * ca) * shrink;
    // 每一缕自己弯来弯去（同一缕在噪声里取同一处，所以一缕是连着的一根；形状随时间慢慢往下流）；中段最大，两头为零
    float so = p.home.w * 37.0;
    float env = pow(sin(3.14159265 * k), 0.8) * (0.4 + 0.6 * shrink);
    float mx = cd_noise2(float2(so, k * 2.3 - t * 0.32)) - 0.5;
    float mz = cd_noise2(float2(so + 71.3, k * 1.9 - t * 0.27)) - 0.5;
    // 刚脱落的一下往外迸一点（卡下沿那一片碎光），很快就收回路径上
    float3 r3 = float3(cd_hash11(p.home.z * 13.1) - 0.5, cd_hash11(p.home.z * 7.7) - 0.5, cd_hash11(p.home.z * 3.3) - 0.5);
    float burst = (1.0 - exp(-age * 9.0)) * exp(-age * 4.0);
    float3 x = float3(T.x + L.x + mx * 2.0 * U.params.z * env, y, T.z + L.y + mz * 2.0 * U.params.z * env)
             + r3 * float3(0.10, 0.05, 0.10) * burst;
    float3 v = (x - p.pos.xyz) / max(dt, 1.0e-4);

    float bright = p.vel.w;
    if (s >= 1.0) bright -= dt * 9.0;                 // 到了：被按钮那一点的光收进去
    bright = min(bright, U.timing.w + 0.15);          // 收尾时整体变淡
    if (bright <= 0.002) {
        p.pos.w = 1.0e4;
        p.vel.w = 0.0;
        ps[id] = p;
        return;
    }
    p.pos = float4(x, age);
    p.vel = float4(v, bright);
    ps[id] = p;
}

// MARK: 粒子 → 细光线（按速度拉长的薄片，两头圆）

struct CDLineOut {
    float4 pos [[position]];
    float2 local;
    float3 color;
};

vertex CDLineOut cd_line_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                const device CDParticle *ps [[buffer(0)]],
                                constant CDUniforms &U [[buffer(1)]]) {
    CDParticle p = ps[iid];
    CDLineOut o;
    o.local = float2(0);
    o.color = float3(0);
    if (p.pos.w < 0.0 || p.pos.w >= 1.0e4 || p.vel.w <= 0.002) {
        o.pos = float4(2.0, 2.0, 2.0, 1.0);   // 画面外的退化三角形
        return o;
    }
    float4 a = U.viewProj * float4(p.pos.xyz, 1.0);
    float trailT = 0.07 + 0.06 * cd_hash11(p.home.z * 5.3);
    float4 b = U.viewProj * float4(p.pos.xyz - p.vel.xyz * trailT, 1.0);
    float2 sa = a.xy / a.w, sb = b.xy / b.w;
    float2 half_px = float2(U.screen.x, U.screen.y) * 0.5;
    float2 dir = (sa - sb) * half_px;
    float len = length(dir);
    float2 td = len > 0.5 ? dir / len : float2(0.0, 1.0);
    float2 nr = float2(-td.y, td.x);
    float fresh = exp(-p.pos.w * 3.5);                   // 刚脱落的一下更亮、更粗一点（闪一下）
    float w = U.screen.z * (0.65 + 0.7 * cd_hash11(p.home.z * 3.7)) * (1.0 + fresh * 0.8);
    float side = (vid & 1) ? 1.0 : -1.0;
    bool head = vid >= 2;
    float2 base = head ? sa : sb;
    float2 ext = head ? td * w : -td * w;
    float2 ndc = base + (nr * side * w + ext) / half_px;
    o.pos = float4(ndc, 0.0, 1.0);
    o.local = float2(side, head ? 1.0 : -1.0);
    float hue = fract(p.home.w + p.home.x * 0.8 + U.timing.x * 0.03);
    float near = saturate(1.0 - distance(p.pos.xyz, U.target.xyz) / 1.1);
    float3 c = mix(float3(1.0), cd_spectral(hue), 0.2) * (1.0 + near * 0.9);
    c = mix(c, float3(2.2), fresh * 0.5);
    // 一缕一缕亮暗不一（几根亮的、多数淡的），整束光才有层次、缕与缕之间看得出空
    float strandLum = 0.3 + 0.7 * pow(cd_hash11(p.home.w * 53.9), 1.6);
    o.color = c * p.vel.w * strandLum;
    return o;
}

fragment float4 cd_line_fragment(CDLineOut in [[stage_in]]) {
    float across = 1.0 - in.local.x * in.local.x;
    float along = smoothstep(-1.0, -0.1, in.local.y);
    float a = across * across * mix(0.3, 1.0, along);
    // 每一条都很淡：几十条叠在一缕上才是一根亮的光纤，缕与缕之间留黑
    return float4(in.color * a * 0.06, 0.0);
}

// MARK: 卡

struct CDCardOut {
    float4 pos [[position]];
    float3 world;
    float3 nrm;
    float2 uv;
    float face;
    float v;
    float u;
};

vertex CDCardOut cd_card_vertex(uint vid [[vertex_id]],
                                const device CDCardVertex *verts [[buffer(0)]],
                                constant CDUniforms &U [[buffer(1)]]) {
    CDCardVertex cv = verts[vid];
    CDCardOut o;
    float4 w = U.cardModel * float4(cv.pos.xyz, 1.0);
    o.pos = U.viewProj * w;
    o.world = w.xyz;
    o.nrm = (U.cardModel * float4(cv.nrm.xyz, 0.0)).xyz;
    o.uv = cv.uv.xy;
    o.face = cv.pos.w;
    o.v = cv.uv.z;
    o.u = cv.uv.w;
    return o;
}

fragment float4 cd_card_fragment(CDCardOut in [[stage_in]],
                                 texture2d<float> frontTex [[texture(0)]],
                                 texture2d<float> backTex [[texture(1)]],
                                 constant CDUniforms &U [[buffer(1)]]) {
    float2 cardUV = float2(in.u, in.v);
    float edge = in.v + cd_jag(cardUV) - U.timing.z;
    if (edge < 0.0) discard_fragment();
    constexpr sampler s(filter::linear, address::clamp_to_edge, mip_filter::none);
    float3 base;
    if (in.face < 0.5) base = frontTex.sample(s, in.uv).rgb;
    else if (in.face < 1.5) base = backTex.sample(s, in.uv).rgb;
    else base = float3(0.045, 0.045, 0.05);

    float3 N = normalize(in.nrm);
    float3 V = normalize(U.camera.xyz - in.world);
    if (dot(N, V) < 0.0) N = -N;
    float3 L = normalize(float3(-0.45, 0.75, 0.85));
    float3 L2 = normalize(float3(0.8, -0.2, 0.6));
    float diff = saturate(dot(N, L)) * 0.55 + saturate(dot(N, L2)) * 0.15 + 0.42;
    float3 H = normalize(L + V);
    float spec = pow(saturate(dot(N, H)), 70.0) * 0.45;
    float fres = pow(1.0 - saturate(dot(N, V)), 4.0) * 0.35;
    // 侧边：一条细亮的边光（「边缘的高光要克制」）
    float rim = in.face > 1.5 ? 0.18 : 0.0;
    float3 c = base * diff + spec + fres * float3(0.75, 0.82, 1.0) + rim;

    // 溶解前沿：一道亮边，上面一截（卡高的一成多）是一格格闪烁的「数据」方块（参照录屏：卡的下沿化成一片碎光）
    float edgeLine = 1.0 - smoothstep(0.0, 0.02, edge);
    float band = 1.0 - smoothstep(0.0, 0.24, edge);
    float2 cellId = floor(in.uv * float2(56.0, 76.0));
    float cell = cd_hash21(cellId + floor(U.timing.x * 12.0 + cd_hash21(cellId) * 3.0));
    float on = step(1.0 - 0.8 * pow(band, 1.6), cell);
    float3 tint = mix(float3(1.0), cd_spectral(fract(in.u * 1.7 + cellId.y * 0.05 + U.timing.x * 0.2)), 0.35);
    c = mix(c * (1.0 - 0.5 * band), tint * (1.1 + 1.5 * band), on * saturate(band * 1.6));
    c = mix(c, float3(2.2), edgeLine * edgeLine);
    c *= U.trail.w;
    return float4(c, 1.0);
}

// MARK: 全屏的几遍

struct CDFullOut {
    float4 pos [[position]];
    float2 uv;
};

vertex CDFullOut cd_full_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    CDFullOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

/// 拖尾：上一帧往下、往汇聚点那条竖轴挪一点，乘保留比例，加上这一帧的光线
fragment float4 cd_trail_fragment(CDFullOut in [[stage_in]],
                                  texture2d<float> prev [[texture(0)]],
                                  texture2d<float> lines [[texture(1)]],
                                  constant CDUniforms &U [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_zero);
    float2 uv = in.uv;
    float2 adv = float2((uv.x - U.targetScreen.x) * 0.003, -0.003);
    float3 p = prev.sample(s, uv + adv).rgb * U.trail.x;
    float3 n = lines.sample(s, uv).rgb;
    return float4(p + n * 0.1, 1.0);
}

/// 辉光的输入：亮的部分（光线 + 拖尾 + 卡上那条溶解光带），1/4 分辨率
fragment float4 cd_bright_fragment(CDFullOut in [[stage_in]],
                                   texture2d<float> lines [[texture(0)]],
                                   texture2d<float> trails [[texture(1)]],
                                   texture2d<float> card [[texture(2)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = lines.sample(s, in.uv).rgb + trails.sample(s, in.uv).rgb * 0.8;
    c = max(c - 0.5, 0.0);
    float3 k = card.sample(s, in.uv).rgb;
    c += max(k - 0.9, 0.0) * 1.5;
    return float4(c, 1.0);
}

/// 可分离的高斯（9 点，线性采样合并成 5 次）
fragment float4 cd_blur_fragment(CDFullOut in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 constant float4 &dir [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 st = dir.xy;
    float3 c = src.sample(s, in.uv).rgb * 0.2270270270;
    c += (src.sample(s, in.uv + st * 1.3846153846).rgb + src.sample(s, in.uv - st * 1.3846153846).rgb) * 0.3162162162;
    c += (src.sample(s, in.uv + st * 3.2307692308).rgb + src.sample(s, in.uv - st * 3.2307692308).rgb) * 0.0702702703;
    return float4(c, 1.0);
}

static float3 cd_aces(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

/// 合成：卡 + 光线（侧向色散）+ 拖尾 + 辉光 + 光源（光晕、横向镜头光、往上的光束、衍射环）+ 底部的冷色环境光
fragment float4 cd_composite_fragment(CDFullOut in [[stage_in]],
                                      texture2d<float> card [[texture(0)]],
                                      texture2d<float> lines [[texture(1)]],
                                      texture2d<float> trails [[texture(2)]],
                                      texture2d<float> bloomA [[texture(3)]],
                                      texture2d<float> bloomB [[texture(4)]],
                                      constant CDUniforms &U [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float2 tp = U.targetScreen.xy;
    float aspect = U.targetScreen.z;

    // 色散（棱镜那样）：沿横向取五处，红偏一边、蓝偏另一边、中间偏绿 —— 每一缕细光纤两边是一道连续的彩虹边，中间是白的；
    // 离中轴越远偏得越多。卡（尤其溶解那一截碎光）也带一点（参照录屏）
    float ca = U.trail.y * (0.006 + 0.006 * abs(uv.x - tp.x));
    const float3 W[5] = { float3(0.0, 0.05, 0.45), float3(0.0, 0.25, 0.35), float3(0.2, 0.4, 0.2), float3(0.35, 0.25, 0.0), float3(0.45, 0.05, 0.0) };
    float3 streams = float3(0.0), cardC = float3(0.0);
    for (int i = 0; i < 5; i++) {
        float o = float(i) * 0.5 - 1.0;
        float2 off = float2(ca * o, 0.0);
        streams += (lines.sample(s, uv + off).rgb + trails.sample(s, uv + off * 1.4).rgb) * W[i];
        cardC += card.sample(s, uv + off * 0.45).rgb * W[i];
    }
    float3 bloom = bloomA.sample(s, uv).rgb * 0.26 + bloomB.sample(s, uv).rgb * 0.2;

    // 光源：按钮后面一团横向的白热柔光（比胶囊宽一点、比胶囊高一倍，稍微偏上 —— 光纤从上面扎进来），外面一圈暖白的光晕；
    // 两边一排带彩边的大光斑；收尾时从按钮往上散开一片光束、光斑更多更亮（参照录屏的最后一秒）
    float I = U.screen.w;
    float endK = U.camera.w;
    float2 d = (uv - tp) * float2(aspect, 1.0);
    float r = length(d);
    float2 dc = d - float2(0.0, -0.012);
    float2 de = dc * float2(0.3, 1.0);
    float re = length(de);
    float core = exp(-dot(de, de) / 0.0010) * 2.4;
    float halo = exp(-re / 0.06) * 0.85;
    float wide = exp(-r / 0.24) * 0.12;
    float ang = atan2(d.y, d.x);
    float up = smoothstep(0.02, -0.06, d.y);
    float rays = pow(cd_noise2(float2(ang * 16.0, U.targetScreen.w * 0.08)), 3.0) * smoothstep(0.03, 0.14, r) * exp(-r / 0.5) * up;
    float3 bokeh = float3(0.0);
    for (int k = 0; k < 8; k++) {
        float fk = float(k);
        float side = (k % 2 == 0) ? 1.0 : -1.0;
        float2 c0 = float2(side * (0.13 + 0.05 * fk + 0.03 * cd_hash11(fk * 2.9)), 0.03 * cd_hash11(fk * 3.7) - 0.02 - 0.008 * fk);
        float rad = 0.03 + 0.035 * cd_hash11(fk * 9.1);
        float dist = length(d - c0);
        float disc = smoothstep(rad, rad * 0.6, dist);
        float rim = exp(-pow((dist - rad * 0.88) / (rad * 0.16), 2.0));
        float3 tint = cd_spectral(fract(fk * 0.23 + dist * 5.0));
        float on = (k < 4) ? (0.35 * I + 0.65 * endK) : endK;
        bokeh += (mix(float3(0.9, 0.92, 1.0), tint, 0.45) * disc * 0.09 + tint * rim * 0.16) * (0.5 + 0.5 * cd_hash11(fk * 5.3)) * on;
    }
    float3 light = (float3(1.0, 0.97, 0.93) * (core + halo) + float3(1.0, 0.93, 0.86) * wide) * I
                 + float3(0.9, 0.95, 1.0) * rays * (0.05 * I + 0.32 * endK)
                 + bokeh;

    // 环境光：从底下泛起，左边青蓝、右边暖紫（参照录屏后半段）
    float3 ambCol = mix(float3(0.08, 0.25, 0.30), float3(0.33, 0.17, 0.26), smoothstep(0.25, 0.85, uv.x));
    float3 amb = ambCol * smoothstep(0.30, 1.05, uv.y) * U.trail.z;

    // 四周很淡的放射线（空间感）：清除一开始就有，跟光源一起亮
    float streak = pow(cd_noise2(float2(ang * 70.0, 2.0)), 10.0) * smoothstep(0.15, 0.9, r) * 0.035 * I;

    float3 c = cardC + streams + bloom + light + amb + streak;
    return float4(cd_aces(c * 1.05), 1.0);
}
