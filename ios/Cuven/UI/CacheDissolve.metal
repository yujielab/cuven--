#include <metal_stdlib>
using namespace metal;

// 清除缓存的动画「Prismatic Data Dissolution」（用户要求，参照他发来的录屏）：
// 一张浮在黑底上的 3D 存储卡从下沿开始化成光点 → 光点被一个旋度噪声流场带着往下流、越往下越往中轴收，拉成一缕缕光纤 →
// 汇进底部进度胶囊那一点的光源（光晕、横向镜头光、往上的光束、很淡的衍射环），四周泛起一层冷色的环境光 → 流变细、光收掉。
// 一帧：粒子更新（计算）→ 卡（带深度）→ 粒子拉成细线（相加混合）→ 拖尾累积（上一帧往下、往中轴挪一点再衰减）→
// 亮部降采样 + 两档高斯模糊（辉光）→ 合成（侧向色散、光源、环境光、ACES 映射）。所有函数名带 cd_ 前缀。

struct CDUniforms {
    float4x4 viewProj;
    float4x4 cardModel;
    float4 camera;        // xyz 相机位置
    float4 timing;        // x 时间，y 这一帧的 dt，z 溶解前沿（卡面 v，0 = 下沿），w 光流整体亮度上限（收尾时降到 0）
    float4 target;        // xyz 汇聚点（世界坐标），w 吸收半径
    float4 screen;        // x 宽（像素），y 高，z 光纤线宽（像素），w 光源强度 0…1
    float4 params;        // x 流场强度，y 收向中轴的强度，z 重力，w 粒子数
    float4 targetScreen;  // xy 汇聚点在画面上（uv，y 向下），z 宽高比，w 时间
    float4 cardInfo;      // x 半宽，y 半高，z 半厚，w 是否减弱动态效果（1 = 不放粒子）
    float4 trail;         // x 这一帧的拖尾保留比例，y 色散强度，z 环境光强度，w 卡的整体淡出（0…1）
};

struct CDParticle {
    float4 pos;   // xyz 世界坐标；w < 0 还在卡上，w ≥ 0 脱落后过了多久，w ≥ 1e4 已经被吸收
    float4 vel;   // xyz 速度；w 亮度
    float4 home;  // xy 在卡面上的 uv（v 从下往上），z 随机种子，w 色相
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
        // 还在卡上：跟着卡走；前沿扫过就脱落
        if (U.cardInfo.w < 0.5 && p.home.y + cd_jag(p.home.xy) < front) {
            float3 n = normalize((U.cardModel * float4(0, 0, 1, 0)).xyz);
            float s = p.home.z;
            float3 r = float3(cd_hash11(s * 13.1) - 0.5, cd_hash11(s * 7.7) - 0.5, cd_hash11(s * 3.3) - 0.5);
            p.pos = float4(onCard, 0.0);
            p.vel = float4(n * 0.12 + r * float3(0.25, 0.12, 0.25) + float3(0.0, -0.8, 0.0), 1.0);
        } else {
            p.pos.xyz = onCard;
        }
        ps[id] = p;
        return;
    }
    if (p.pos.w >= 1.0e4) return;

    float3 x = p.pos.xyz, v = p.vel.xyz;
    // 流场：慢慢往下漂（光流整体在流）。每一缕（home.w）在噪声里错开一段：各扭各的、互相缠绕，不会整片一起飘
    float so = p.home.w * 17.0;
    float3 q = x * float3(2.0, 1.2, 2.0) + float3(so * 0.37, t * 0.55, so * 0.21 + t * 0.21);
    float3 curl = cd_curl(q) * float3(1.0, 0.45, 1.0);
    float3 toT = U.target.xyz - x;
    float d = length(toT);
    float cardY = U.cardModel[3].y;
    // 0 = 卡那一高度，1 = 汇聚点那一高度
    float k = saturate((cardY - x.y) / max(cardY - U.target.y, 0.001));
    // 往中轴收：从卡下面就开始收，越往下越紧 —— 整束光是一个越来越细的锥，到光源那儿收成一点
    float3 acc = curl * U.params.x * (1.0 - 0.6 * k)
               + float3(0.0, -U.params.z, 0.0)
               + float3(toT.x, 0.0, toT.z) * U.params.y * (0.5 + 1.6 * k + 1.4 * k * k)
               + toT / max(d, 0.05) * (0.3 + 2.2 * k * k * k);
    v = v * exp(-dt * 1.3) + acc * dt;
    float sp = length(v);
    if (sp > 3.0) v *= 3.0 / sp;
    x += v * dt;

    float bright = p.vel.w;
    if (d < U.target.w) bright -= dt * 5.0;            // 被光源吸收
    bright = min(bright, U.timing.w + 0.15);             // 收尾时整体变淡
    if (bright <= 0.002) {
        p.pos.w = 1.0e4;
        p.vel.w = 0.0;
        ps[id] = p;
        return;
    }
    p.pos = float4(x, p.pos.w + dt);
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
    float trailT = 0.11 + 0.08 * cd_hash11(p.home.z * 5.3);
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
    float3 c = mix(float3(1.0), cd_spectral(hue), 0.32) * (1.0 + near * 0.7);
    c = mix(c, float3(2.2), fresh * 0.5);
    o.color = c * p.vel.w;
    return o;
}

fragment float4 cd_line_fragment(CDLineOut in [[stage_in]]) {
    float across = 1.0 - in.local.x * in.local.x;
    float along = smoothstep(-1.0, -0.1, in.local.y);
    float a = across * across * mix(0.3, 1.0, along);
    // 每一条都很淡：几十条叠在一缕上才是一根亮的光纤，缕与缕之间留黑
    return float4(in.color * a * 0.03, 0.0);
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

    // 溶解前沿：一窄条白光，带一点光谱色；里面跳着一格格「数据」
    float band = 1.0 - smoothstep(0.0, 0.055, edge);
    float cell = cd_hash21(floor(in.uv * float2(46.0, 62.0)) + floor(U.timing.x * 14.0));
    float3 glow = mix(float3(1.0), cd_spectral(fract(in.u * 1.7 + U.timing.x * 0.2)), 0.35) * (1.5 + 1.6 * step(0.62, cell));
    c = mix(c, glow, band * band);
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
    float2 adv = float2((uv.x - U.targetScreen.x) * 0.0045, -0.0038);
    float3 p = prev.sample(s, uv + adv).rgb * U.trail.x;
    float3 n = lines.sample(s, uv).rgb;
    return float4(p + n * 0.22, 1.0);
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

    // 色散：红往外、蓝往里，离中轴越远偏得越多（光纤两边的彩边），中间是白的
    float ca = U.trail.y * (0.0024 + 0.004 * abs(uv.x - tp.x));
    float2 off = float2(ca, 0.0);
    float3 streams;
    streams.r = lines.sample(s, uv + off).r + trails.sample(s, uv + off * 1.5).r;
    streams.g = lines.sample(s, uv).g + trails.sample(s, uv).g;
    streams.b = lines.sample(s, uv - off).b + trails.sample(s, uv - off * 1.5).b;

    float3 cardC = card.sample(s, uv).rgb;
    float3 bloom = bloomA.sample(s, uv).rgb * 0.35 + bloomB.sample(s, uv).rgb * 0.28;

    float I = U.screen.w;
    float2 d = (uv - tp) * float2(aspect, 1.0);
    float r = length(d);
    float core = exp(-r * r / 0.0007) * 3.2;
    float halo = exp(-r / 0.07) * 0.8;
    float wide = exp(-r / 0.32) * 0.22;
    float flare = exp(-abs(d.y) / 0.005) * exp(-abs(d.x) / 0.30) * 0.75;
    float ang = atan2(d.y, d.x);
    float up = smoothstep(0.02, -0.08, d.y);                          // 光束只往上（画面里 y 向下）
    float rays = pow(cd_noise2(float2(ang * 9.0, U.targetScreen.w * 0.12)), 4.0) * exp(-r / 0.20) * 0.18 * up;
    float3 ring = cd_spectral(fract(r * 7.0 + 0.2)) * exp(-pow((r - 0.12) / 0.018, 2.0)) * 0.10;
    float3 light = (float3(1.0, 0.97, 0.93) * (core + halo) + float3(0.82, 0.9, 1.0) * (wide + flare) + float3(0.9, 0.95, 1.0) * rays + ring) * I;

    // 环境光：从底下泛起的一层青蓝 / 紫（参照录屏后半段）
    float3 ambCol = mix(float3(0.10, 0.24, 0.32), float3(0.30, 0.15, 0.36), smoothstep(0.2, 0.8, uv.x));
    float3 amb = ambCol * smoothstep(0.30, 1.05, uv.y) * U.trail.z;

    // 四周很淡的放射线（空间感），跟光源一起亮
    float streak = pow(cd_noise2(float2(ang * 70.0, 2.0)), 10.0) * smoothstep(0.15, 0.9, r) * 0.035 * I;

    float3 c = cardC + streams + bloom + light + amb + streak;
    return float4(cd_aces(c * 1.05), 1.0);
}
