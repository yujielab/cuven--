#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// 登录页的底图：网页版 web/index.html「Sky Pro 流体」（#cvlViz）的片元着色器逐行移植。
// · 参数就是网页版 CFG 那一组（2026-08-13 导出的配置），autoColor 关着，所以配色是固定的四种灰。
// · 网页版画布上还挂着 CSS 滤镜 saturate(3) brightness(1.2) contrast(1.1) hue-rotate(69deg)。四种配色都是灰
//   （R = G = B），saturate 和 hue-rotate 对灰不起作用；brightness 与 contrast 照 CSS 的算法做，每一步都截到 0–1。
// · 网页版的噪声纹理是 256×256 的随机灰度（REPEAT + LINEAR）。这里用整数散列算出同样分布的格点值，
//   再照纹理采样那样做双线性插值，效果一样，不用另外传一张图。
// · gl_FragCoord 那一路的 out_uv 原点在左上（顶点着色器里翻过 y），和 SwiftUI 的 position 一样。

namespace skyfluid {

constant float WIND_SPEED = 0.737;
constant float WARP_POWER = 0.714;
constant float FBM_STRENGTH = 0.912;
constant float BLUR_RADIUS = 1.2673;
constant float ZOOM = 0.3971;
constant float GRAIN_STRENGTH = 0.0605;
constant float GRAIN_SCALE = 12.0;
constant float NOISE_SCALE = 0.8673;
constant float TIME_MUL = 0.76;
constant float WC_SCALE = 0.0;
constant float WC_STRENGTH = 0.3;
constant float V_OFFSET = 0.09;
constant float WAVE_SPREAD = 1.0;
constant float DAMP = 0.55;
constant float3 AMP = float3(1.5, 1.4, 1.3);
constant float3 FREQ = float3(1.0, 1.0, 1.0);

// CFG.colors：main #000000、low #f1f1f1、mid #808080、high #f0f0f0
constant float3 MAIN = float3(0.0);
constant float3 LOW = float3(241.0 / 255.0);
constant float3 MID = float3(128.0 / 255.0);
constant float3 HIGH = float3(240.0 / 255.0);

// GLSL 的 mod(x, 289.0)：x − y·floor(x / y)（Metal 的 fmod 对负数的结果不一样）
static inline float4 mod289(float4 x) { return x - 289.0 * floor(x / 289.0); }
static inline float3 mod289(float3 x) { return x - 289.0 * floor(x / 289.0); }

static float3 blendLinearBurn(float3 base, float3 blend, float opacity) {
    return max(base + blend - float3(1.0), float3(0.0)) * opacity + base * (1.0 - opacity);
}

static float4 permute(float4 x) { return mod289((x * 34.0 + 1.0) * x); }
static float4 taylorInvSqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }
static float3 fade3(float3 t) { return t * t * t * (t * (t * 6.0 - 15.0) + 10.0); }
static float rand(float2 n) { return fract(sin(dot(n, float2(12.9898, 4.1414))) * 43758.5453); }

static float noise2(float2 p) {
    float2 ip = floor(p);
    float2 u = fract(p);
    u = u * u * (3.0 - 2.0 * u);
    return pow(mix(mix(rand(ip), rand(ip + float2(1.0, 0.0)), u.x),
                   mix(rand(ip + float2(0.0, 1.0)), rand(ip + float2(1.0, 1.0)), u.x), u.y), 2.0);
}

static float fbm(float2 x) {
    float v = 0.0;
    float a = 0.5;
    float2 shift = float2(100.0);
    // GLSL mat2(cos, sin, −sin, cos) 按列填：第一列 (cos, sin)，第二列 (−sin, cos)
    float2x2 rot = float2x2(float2(cos(0.5), sin(0.5)), float2(-sin(0.5), cos(0.5)));
    for (int i = 0; i < 4; ++i) {
        v += a * noise2(x);
        x = rot * x * 2.0 + shift;
        a *= 0.5;
    }
    return v;
}

static float cnoise(float3 P) {
    float3 Pi0 = floor(P);
    float3 Pi1 = Pi0 + float3(1.0);
    Pi0 = mod289(Pi0);
    Pi1 = mod289(Pi1);
    float3 Pf0 = fract(P);
    float3 Pf1 = Pf0 - float3(1.0);
    float4 ix = float4(Pi0.x, Pi1.x, Pi0.x, Pi1.x);
    float4 iy = float4(Pi0.y, Pi0.y, Pi1.y, Pi1.y);
    float4 iz0 = float4(Pi0.z);
    float4 iz1 = float4(Pi1.z);
    float4 ixy = permute(permute(ix) + iy);
    float4 ixy0 = permute(ixy + iz0);
    float4 ixy1 = permute(ixy + iz1);
    float4 gx0 = ixy0 / 7.0;
    float4 gy0 = fract(floor(gx0) / 7.0) - 0.5;
    gx0 = fract(gx0);
    float4 gz0 = float4(0.5) - abs(gx0) - abs(gy0);
    float4 sz0 = step(gz0, float4(0.0));
    gx0 -= sz0 * (step(float4(0.0), gx0) - 0.5);
    gy0 -= sz0 * (step(float4(0.0), gy0) - 0.5);
    float4 gx1 = ixy1 / 7.0;
    float4 gy1 = fract(floor(gx1) / 7.0) - 0.5;
    gx1 = fract(gx1);
    float4 gz1 = float4(0.5) - abs(gx1) - abs(gy1);
    float4 sz1 = step(gz1, float4(0.0));
    gx1 -= sz1 * (step(float4(0.0), gx1) - 0.5);
    gy1 -= sz1 * (step(float4(0.0), gy1) - 0.5);
    float3 g000 = float3(gx0.x, gy0.x, gz0.x);
    float3 g100 = float3(gx0.y, gy0.y, gz0.y);
    float3 g010 = float3(gx0.z, gy0.z, gz0.z);
    float3 g110 = float3(gx0.w, gy0.w, gz0.w);
    float3 g001 = float3(gx1.x, gy1.x, gz1.x);
    float3 g101 = float3(gx1.y, gy1.y, gz1.y);
    float3 g011 = float3(gx1.z, gy1.z, gz1.z);
    float3 g111 = float3(gx1.w, gy1.w, gz1.w);
    float4 norm0 = taylorInvSqrt(float4(dot(g000, g000), dot(g010, g010), dot(g100, g100), dot(g110, g110)));
    g000 *= norm0.x; g010 *= norm0.y; g100 *= norm0.z; g110 *= norm0.w;
    float4 norm1 = taylorInvSqrt(float4(dot(g001, g001), dot(g011, g011), dot(g101, g101), dot(g111, g111)));
    g001 *= norm1.x; g011 *= norm1.y; g101 *= norm1.z; g111 *= norm1.w;
    float n000 = dot(g000, Pf0);
    float n100 = dot(g100, float3(Pf1.x, Pf0.y, Pf0.z));
    float n010 = dot(g010, float3(Pf0.x, Pf1.y, Pf0.z));
    float n110 = dot(g110, float3(Pf1.x, Pf1.y, Pf0.z));
    float n001 = dot(g001, float3(Pf0.x, Pf0.y, Pf1.z));
    float n101 = dot(g101, float3(Pf1.x, Pf0.y, Pf1.z));
    float n011 = dot(g011, float3(Pf0.x, Pf1.y, Pf1.z));
    float n111 = dot(g111, Pf1);
    float3 fxyz = fade3(Pf0);
    float4 nz = mix(float4(n000, n100, n010, n110), float4(n001, n101, n011, n111), fxyz.z);
    float2 nyz = mix(nz.xy, nz.zw, fxyz.y);
    return 2.2 * mix(nyz.x, nyz.y, fxyz.x);
}

/// 网页版噪声纹理的一个格点：0…254 的随机整数 ÷ 255（Uint8 纹理），按 256 取模铺开（REPEAT）
static float texel(int2 p) {
    uint2 q = uint2(p & int2(255));
    uint h = q.x * 0x27d4eb2du ^ (q.y * 0x165667b1u + 0x9e3779b9u);
    h ^= h >> 15; h *= 0x85ebca6bu;
    h ^= h >> 13; h *= 0xc2b2ae35u;
    h ^= h >> 16;
    return floor(float(h & 0xffffu) / 65536.0 * 255.0) / 255.0;
}

/// texture(uTextureNoise, uv)：256×256、REPEAT、LINEAR 的双线性采样
static float noiseTex(float2 uv) {
    float2 p = uv * 256.0 - 0.5;
    float2 i = floor(p);
    float2 f = p - i;
    int2 i0 = int2(i);
    float a = texel(i0);
    float b = texel(i0 + int2(1, 0));
    float c = texel(i0 + int2(0, 1));
    float d = texel(i0 + int2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static float3 fluidColor(float2 st, float time) {
    float scaleFactor = 1.0 / (2.0 * ZOOM);
    float2 uv = st * scaleFactor + 0.5;
    uv.y = 1.0 - uv.y;
    float verticalOffset = V_OFFSET;
    float blurRadius = BLUR_RADIUS;
    time *= TIME_MUL;
    verticalOffset += 1.0 - WAVE_SPREAD;
    float noiseX = cnoise(float3(uv * NOISE_SCALE + float2(0.0, 74.8572), time * 0.3));
    float noiseY = cnoise(float3(uv * NOISE_SCALE + float2(203.91282, 10.0), time * 0.3));
    uv += float2(noiseX * 2.0, noiseY) * WARP_POWER;
    float noiseA = cnoise(float3(uv * WC_SCALE + float2(344.91282, 0.0), time * 0.3))
                 + cnoise(float3(uv * WC_SCALE * 2.2 + float2(723.937, 0.0), time * 0.4)) * 0.5;
    uv += noiseA * WC_STRENGTH;
    uv.y -= verticalOffset;
    float2 texUv = uv * GRAIN_SCALE;
    float wobble = (sin(time) + 1.0) * 0.5;
    float tR0 = noiseTex(texUv);
    float tG0 = noiseTex(float2(texUv.x, 1.0 - texUv.y));
    float disp0 = mix(tR0 - 0.5, tG0 - 0.5, wobble) * GRAIN_STRENGTH;
    texUv += float2(63.861, 368.937);
    float tR1 = noiseTex(texUv);
    float tG1 = noiseTex(float2(texUv.x, 1.0 - texUv.y));
    float disp1 = mix(tR1 - 0.5, tG1 - 0.5, wobble) * GRAIN_STRENGTH;
    texUv += float2(272.861 + 180.302, 829.937 + 819.871);
    float tR3 = noiseTex(texUv);
    float tG3 = noiseTex(float2(texUv.x, 1.0 - texUv.y));
    float disp3 = mix(tR3 - 0.5, tG3 - 0.5, wobble) * GRAIN_STRENGTH;
    uv += disp0;
    float2 stFbm = uv * NOISE_SCALE;
    float2 q = float2(fbm(stFbm * 0.5 + WIND_SPEED * time), fbm(stFbm * 0.5 + WIND_SPEED * time));
    float2 r = float2(fbm(stFbm + 1.0 * q + float2(0.3, 9.2) + 0.15 * time),
                      fbm(stFbm + 1.0 * q + float2(8.3, 0.8) + 0.126 * time));
    float f = fbm(stFbm + r - q);
    float fullFbm = (f + 0.6 * f * f + 0.7 * f + 0.5) * 0.5;
    fullFbm = pow(fullFbm, DAMP) * FBM_STRENGTH;
    blurRadius *= 1.5;
    float2 snUv = (uv + float2((fullFbm - 0.5) * 1.2) + float2(0.0, 0.025) + disp0) * float2(FREQ.x, 1.0);
    float sn = noise2(snUv * 2.0 + float2(0.0, time * 0.5)) * 2.0 * AMP.x;
    float sn2 = pow(smoothstep(sn - 1.2 * blurRadius, sn + 1.2 * blurRadius, (snUv.y - 0.5 * WAVE_SPREAD) * 5.0 + 0.5), 0.8);
    float2 snUvB = (uv + float2((fullFbm - 0.5) * 0.85) + float2(0.0, 0.025) + disp1) * float2(FREQ.y, 1.0);
    float snB = noise2(snUvB * 4.0 + float2(293.0, time * 1.0)) * 2.0 * AMP.y;
    float sn2B = pow(smoothstep(snB - 0.9 * blurRadius, snB + 0.9 * blurRadius, (snUvB.y - 0.6 * WAVE_SPREAD) * 5.0 + 0.5), 0.9);
    float2 snUvC = (uv + float2((fullFbm - 0.5) * 1.1) + disp3) * float2(FREQ.z, 1.0);
    float snC = noise2(snUvC * 6.0 + float2(153.0, time * 1.2)) * 2.0 * AMP.z;
    float sn2C = smoothstep(snC - 0.7 * blurRadius, snC + 0.7 * blurRadius, (snUvC.y - 0.9 * WAVE_SPREAD) * 6.0 + 0.5);
    float3 color = blendLinearBurn(MAIN, LOW, 1.0 - sn2);
    color = blendLinearBurn(color, mix(MAIN, MID, 1.0 - sn2B), sn2);
    color = mix(color, mix(MAIN, HIGH, 1.0 - sn2C), sn2 * sn2B);
    return color;
}

} // namespace skyfluid

/// size：整屏大小（点；着色器只用它的宽高比和归一化坐标，画在比整屏矮的一块上时图案也不变）；time：网页版的 u_time
[[ stitchable ]] half4 cuvenSkyFluid(float2 position, half4 color, float2 size, float time) {
    float2 outUV = position / size;
    float2 st = outUV - 0.5;
    st.x *= size.x / size.y;
    float3 c = skyfluid::fluidColor(st, time);
    // CSS filter：brightness(1.2) → contrast(1.1)（灰色上 saturate、hue-rotate 不起作用）
    c = clamp(c * 1.2, 0.0, 1.0);
    c = clamp((c - 0.5) * 1.1 + 0.5, 0.0, 1.0);
    return half4(half3(c), 1.0h);
}
