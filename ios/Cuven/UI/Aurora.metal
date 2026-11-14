#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// 播放加载画面的极光：网页版 web/index.html 的 Aurora（FIELD + FINISH 两段 GLSL）逐行移植。
// 常量、配色、推进方式都和网页版一样；网页版在 25% 分辨率的离屏纹理里画、再线性放大，
// 这里由 SwiftUI 在一块小画布上跑这段着色器、再整块放大（PlayerLoading.swift 的 AuroraView），结果一样。
// 背景是暗色（uPaper = 0），FINISH 这一段就只剩「底色 + 光 ×（1 − 底色）」，直接并在最后。

constant float LAYERS = 84.0;
constant float TWIST = 1.250;
constant float DRAG = 0.180;
constant float GAIN = 0.62;
constant float2 CENTRE = float2(-0.62, 0.24);
constant float TILT = 0.6;
constant float ZOOM = 1.05;
constant float THETA = 2.13;
constant float SHEAR = 0.963;
constant float SHRINK = 0.953;
constant float2 WARP_FREQ = float2(0.42, 2.4);
constant float2 WARP_AMP = float2(0.13, 0.027);
constant float2 ASPECT = float2(2.1, 0.17);
constant float OFFSET = 0.36;
constant float GLOW = 0.0021;
constant float SOFT = 0.0019;
constant float FALLOFF = 0.37;
constant float PHASE = 12.0;
constant float CYCLE = 0.16;
constant float HUE_TRAVEL = 2.0;

// 网页版 OPT：background [10, 9, 15]、color1 [46, 85, 242]、color2 [133, 231, 255]、size 114、angle −119°
constant float3 BG = float3(10.0, 9.0, 15.0) / 255.0;
constant float3 C1 = float3(46.0, 85.0, 242.0) / 255.0;
constant float3 C2 = float3(133.0, 231.0, 255.0) / 255.0;
constant float SIZE = 1.14;
constant float ANGLE = -119.0 * M_PI_F / 180.0;

// GLSL 的 mat2(c, s, -s, c)：按列填（第一列 (c, s)，第二列 (-s, c)），Metal 的 float2x2 也是按列
static float2x2 rot(float a) {
    float c = cos(a), s = sin(a);
    return float2x2(float2(c, s), float2(-s, c));
}

/// size：画布大小（点）；time：网页版的 time；mouse / on / reach / vel：手指（网页版的 uMouse、uOn、uReach、uVel，已经归一化）
[[ stitchable ]] half4 cuvenAurora(float2 position, half4 color, float2 size, float time,
                                   float2 mouse, float on, float reach, float2 vel) {
    float2 R = size;
    // gl_FragCoord 原点在左下，SwiftUI 的 position 原点在左上
    float2 frag = float2(position.x, R.y - position.y);
    float2 pos = (frag - 0.5 * R) / R.y;

    float2 d = pos - mouse;
    float w = on * exp(-dot(d, d) / (reach * reach));
    if (w > 1e-4) pos = mouse + rot(w * TWIST) * d * (1.0 - 0.3 * min(w, 1.0)) - vel * min(w, 1.0) * DRAG;

    pos = rot(ANGLE) * pos / SIZE;
    float t = time * 0.49 + PHASE;
    float breath = (-sin(time * 0.735) + sin(time * 0.49 + 1.0)) * 0.25 + 0.5;
    float2 u = rot(TILT) * ((pos - CENTRE) * (ZOOM - breath * 0.085));
    float2x2 fold = float2x2(float2(cos(THETA), sin(THETA)), float2(-SHEAR, cos(THETA)));

    float3 col = float3(0.0);
    for (float i = 1.0; i <= LAYERS; i += 1.0) {
        u.x -= sin(u.y * WARP_FREQ.x + t + i * 0.007) * WARP_AMP.x;
        u.y -= sin(u.x * WARP_FREQ.y - t + i * 0.02) * WARP_AMP.y;
        u = fold * u * SHRINK;
        float2 q = (u - float2(OFFSET + breath * 0.1, 0.0)) * ASPECT;
        float g = GLOW / (dot(q, q) + SOFT) * (0.25 + breath * 0.4);
        float r = length(u);
        float k = sin(i * CYCLE + t * 1.2 + r * HUE_TRAVEL) * 0.5 + 0.5;
        col += g * mix(C1, C2, k) * (0.62 + 0.5 * k) * exp2(-r * FALLOFF);
    }
    float3 x = max(col * GAIN, 0.0);
    col = (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
    col = pow(clamp(col, 0.0, 1.0), float3(0.85, 0.92, 0.98));
    col *= 1.0 - smoothstep(0.5, 1.6, length(pos)) * 0.07;

    // FINISH（暗色底，uPaper = 0）：底色 + 光 ×（1 − 底色）
    float3 L = max(col, 0.0);
    float3 outc = BG + L * (1.0 - BG);
    return half4(half3(clamp(outc, 0.0, 1.0)), 1.0h);
}
