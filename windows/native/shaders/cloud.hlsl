// 光学配对的粒子云（D3D11）：web/pair.js 那两段 GLSL 的逐行移植，运动全在顶点着色器里，粒子缓冲是静态的。
// 点精灵 → 实例化的四边形（每个粒子 4 个顶点，三角带）。码就一处：像素着色器里光学深度乘上码纹理的 M。

cbuffer Cloud : register(b0)
{
    float2 u_scale;
    float2 u_center;
    float u_spriteScale;
    float u_phase;
    float u_gathering;
    float u_codeExt;
    float2 u_codeRot;
    float2 u_densityScale;
    float4 u_densityOrigins;
    float u_densityBlend;
    float u_codeScale;
    float2 u_viewport;
};

Texture2D<float> u_density : register(t0);
Texture2D<float> u_code : register(t1);
SamplerState s_linear : register(s0);

struct VIn
{
    float4 a_position : POSITION;
    float4 a_detail : DETAIL;
    uint vid : SV_VertexID;
};

struct VOut
{
    float4 pos : SV_Position;
    float4 color : COLOR0;
    float2 cloudUv : TEXCOORD0;
    float2 codeUv : TEXCOORD1;
    float2 pc : TEXCOORD2;
};

// GLSL 的 mat2(c, s, -s, c) * v（列主序）
float2 turn(float a, float2 v)
{
    float c = cos(a), s = sin(a);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

float3 rollCloud(float3 p, float phase)
{
    float3 axis = normalize(float3(0.17, 0.98, 0.09));
    float latitude = dot(p, axis);
    float slip = 0.16 * latitude + (0.075 + 0.14 * latitude * latitude) * sin(phase * 2.0 + 2.5 * latitude);
    float angle = phase + slip + 0.105 * sin(2.0 * phase - 0.38);
    float c = cos(angle);
    float3 rolled = p * c + cross(axis, p) * sin(angle) + axis * latitude * (1.0 - c);
    rolled.xy = turn(0.085 * sin(phase + 0.8) + 0.036 * sin(3.0 * phase), rolled.xy);
    return rolled;
}

float3 flow(float3 p, float phase, float strength)
{
    float3 drift = sin(phase * float3(2.0, -1.0, 2.0) + float3(0.4, 1.9, 4.3));
    float3 q = p + strength * 0.109 * sin(p.yzx * float3(7.0, 6.7, 6.2) + p.zxy * float3(3.2, 3.7, 2.8) + phase * float3(2.0, -1.0, 2.0) + float3(2.0, 0.5, 4.4) + drift);
    q += strength * 0.054 * sin(q.zxy * float3(11.0, 12.0, 11.5) + q.yzx * 4.2 + phase * float3(-2.0, 3.0, -3.0) + float3(1.0, 5.0, 2.1));
    q += strength * 0.024 * sin(q.yzx * 21.0 + q.zxy * 8.0 + phase * float3(3.0, 3.0, -3.0));
    return q;
}

float3 wispPosition(float4 a_position, float4 a_detail, float phase, float variation, out float taper)
{
    float angle = a_position.x, elevation = a_position.y, along = a_position.z, idPhase = a_position.w;
    float seed = a_detail.x, spread = a_detail.y, depthSpread = a_detail.z;
    angle += 0.14 * sin(phase * 2.0 + idPhase) + 0.06 * sin(phase * 3.0 - idPhase);
    elevation += 0.12 * sin(phase * 2.0 - idPhase) + 0.055 * cos(phase * 3.0 + 1.7 * idPhase);
    float ce = cos(elevation);
    float3 normal = float3(ce * cos(angle), ce * sin(angle), sin(elevation));
    float3 tangent = float3(-sin(angle), cos(angle), 0.0);
    float3 bitangent = cross(normal, tangent);
    float tilt = 0.75 * sin(idPhase * 1.7) + 0.32 * sin(phase * 2.0 + idPhase);
    float3 across = tangent * cos(tilt) + bitangent * sin(tilt);
    float3 sideways = cross(normal, across);
    float len = 0.46 + 0.14 * sin(idPhase) + 0.07 * sin(phase * 3.0 + idPhase);
    float arc = len * along + 0.026 * sin(along * 6.0 - phase * 2.0 + idPhase);
    float curl = 0.19 * (along * along - 0.25) + 0.083 * sin(along * 3.2 + phase * 3.0 + idPhase) + 0.033 * sin(along * 8.0 - phase * 2.0 + idPhase);
    float gathering = 0.5 + 0.5 * sin(phase * 3.0 + idPhase + 0.53 * along);
    gathering = 0.25 + 0.75 * gathering * gathering;
    float width = (0.009 + 0.022 * seed) * (0.85 + 0.47 * along * along) + (1.0 - variation * gathering) * 0.046;
    taper = (1.0 - smoothstep(0.49, 1.0, abs(along))) * gathering;
    float radius = 0.91 + 0.073 * sin(idPhase * 2.4 + phase * 2.0) + 0.056 * sin(along * 4.5 + idPhase);
    return (radius + depthSpread * width * 0.86) * (normal * cos(arc) + across * sin(arc)) + sideways * (curl + spread * width);
}

VOut VS(VIn i)
{
    float4 a_position = i.a_position, a_detail = i.a_detail;
    float phase = u_phase, variation = u_gathering, kind = a_detail.w, seed = a_detail.x, taper = 1.0;
    float3 pt;
    float strength;
    if (kind > 1.5)
    {
        pt = wispPosition(a_position, a_detail, phase, variation, taper);
        strength = 0.84;
    }
    else
    {
        pt = a_position.xyz;
        float wave = sin(dot(pt, float3(4.4, -3.5, 2.7)) + phase * 2.0);
        float lobe = sin(dot(pt, float3(2.1, 4.6, -3.7)) - phase * 3.0);
        pt *= 1.0 + 0.058 * wave + 0.042 * lobe;
        strength = kind < 0.5 ? 1.0 : 0.51;
    }
    pt = flow(pt, phase, strength * (0.62 + variation * 0.43));
    float3 pockets = sin(pt.yzx * 7.3 + pt.zxy * 5.1 + phase * float3(1.0, -2.0, 1.0));
    float shade = 0.5 + dot(pockets, float3(0.1667, 0.1667, 0.1667));
    pt = rollCloud(pt, phase);
    pt *= 1.0 + 0.018 * sin(phase * 3.0) + 0.011 * cos(phase * 5.0);
    float perspective = 1.0 / (1.0 - 0.14 * pt.z);
    float2 projected = pt.xy * perspective;

    VOut o;
    o.cloudUv = float2(projected.x, -projected.y) / 2.90 + 0.5;
    // 码平面：屏幕上的位置（y 朝下）转一个角度
    float2 cp = float2(projected.x, -projected.y);
    o.codeUv = float2(u_codeRot.x * cp.x - u_codeRot.y * cp.y, u_codeRot.y * cp.x + u_codeRot.x * cp.y) / (2.0 * u_codeExt) + 0.5;
    float size = 1.87 + 1.70 * seed * seed + 0.50 * seed;
    float opacity = 0.32 + 0.19 * (1.0 - seed);
    float grain = kind > 1.5 ? frac(a_position.w * 0.618 + seed * 17.181) : a_detail.z;
    float3 blue = lerp(float3(0.096, 0.470, 0.722), float3(0.124, 0.673, 0.912), grain);
    opacity *= (0.57 + 0.72 * shade) * (0.91 + 0.25 * pt.z);
    if (kind > 1.5)
    {
        blue = lerp(float3(0.042, 0.522, 0.828), float3(0.108, 0.648, 0.924), grain);
        opacity *= (0.22 + 2.40 * taper) * (0.21 + 0.79 * variation);
        opacity *= 0.63 + 0.37 * smoothstep(-0.75, 0.36, pt.z);
        size *= 0.86;
    }
    else if (kind > 0.5)
    {
        blue = lerp(float3(0.21, 0.45, 0.59), float3(0.29, 0.63, 0.74), grain);
        float haloFade = 1.0 - smoothstep(1.14, 1.64, length(pt));
        opacity *= (0.40 + 0.45 * a_detail.y) * haloFade;
        size *= 0.82;
    }
    else
    {
        opacity *= 1.16 * a_detail.y;
    }
    float pixelSize = size * u_spriteScale * perspective;
    opacity *= min(1.0, pixelSize * pixelSize * 0.69);
    float pointSize = max(1.20, pixelSize);
    o.color = float4(blue, min(opacity, 0.95));

    // 点精灵的四个角（三角带 0 1 2 3）：像素尺寸 → 裁剪空间
    float2 corner = float2((i.vid & 1) ? 1.0 : -1.0, (i.vid & 2) ? 1.0 : -1.0);
    o.pc = corner * 0.5;
    o.pos = float4(projected * u_scale + u_center + corner * pointSize / u_viewport, 0.0, 1.0);
    return o;
}

float4 PS(VOut i) : SV_Target
{
    float coverage = 1.0 - smoothstep(0.08, 0.5, length(i.pc));
    float2 offset = saturate(i.cloudUv) * u_densityScale;
    float before = u_density.SampleLevel(s_linear, u_densityOrigins.xy + offset, 0);
    float after = u_density.SampleLevel(s_linear, u_densityOrigins.zw + offset, 0);
    float correction = (lerp(before, after, u_densityBlend) * 255.0 - 128.0) / 44.0;
    // 光学深度 × M：码就这一处
    float gain = exp2(0.90 * correction) * u_code.SampleLevel(s_linear, saturate(i.codeUv), 0) * u_codeScale;
    float opacity = 1.0 - pow(max(1.0 - i.color.a * coverage, 1e-6), gain);
    return float4(i.color.rgb, opacity);
}
