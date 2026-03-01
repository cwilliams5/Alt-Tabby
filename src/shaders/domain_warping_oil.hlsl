// Domain Warping: Oil — converted from Shadertoy (4sBfDw)
// Author: zaiyugi — License: CC BY-NC-SA 3.0
// Based on domain warping article by iq: https://iquilezles.org/articles/warp/warp.htm
// Simplex noise by Ian McEwan, Ashima Arts (MIT License)

cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

#define M_PI 3.14159265359

float3 mod289_3(float3 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float4 mod289_4(float4 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float4 permute(float4 x) {
    return mod289_4(((x * 34.0) + 1.0) * x);
}

float4 taylorInvSqrt(float4 r) {
    return 1.79284291400159 - 0.85373472095314 * r;
}

float snoise(float3 v) {
    const float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
    const float4 D = float4(0.0, 0.5, 1.0, 2.0);

    // First corner
    float3 i = floor(v + dot(v, C.yyy));
    float3 x0 = v - i + dot(i, C.xxx);

    // Other corners
    float3 g = step(x0.yzx, x0.xyz);
    float3 l = 1.0 - g;
    float3 i1 = min(g.xyz, l.zxy);
    float3 i2 = max(g.xyz, l.zxy);

    float3 x1 = x0 - i1 + C.xxx;
    float3 x2 = x0 - i2 + C.yyy;
    float3 x3 = x0 - D.yyy;

    // Permutations
    i = mod289_3(i);
    float4 p = permute(permute(permute(
        i.z + float4(0.0, i1.z, i2.z, 1.0))
        + i.y + float4(0.0, i1.y, i2.y, 1.0))
        + i.x + float4(0.0, i1.x, i2.x, 1.0));

    // Gradients: 7x7 points over a square, mapped onto an octahedron.
    float n_ = 0.142857142857; // 1.0/7.0
    float3 ns = n_ * D.wyz - D.xzx;

    float4 j = p - 49.0 * floor(p * ns.z * ns.z);

    float4 x_ = floor(j * ns.z);
    float4 y_ = floor(j - 7.0 * x_);

    float4 x = x_ * ns.x + ns.yyyy;
    float4 y = y_ * ns.x + ns.yyyy;
    float4 h = 1.0 - abs(x) - abs(y);

    float4 b0 = float4(x.xy, y.xy);
    float4 b1 = float4(x.zw, y.zw);

    float4 s0 = floor(b0) * 2.0 + 1.0;
    float4 s1 = floor(b1) * 2.0 + 1.0;
    float4 sh = -step(h, (float4)0.0);

    float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;

    float3 p0 = float3(a0.xy, h.x);
    float3 p1 = float3(a0.zw, h.y);
    float3 p2 = float3(a1.xy, h.z);
    float3 p3 = float3(a1.zw, h.w);

    // Normalise gradients
    float4 norm = taylorInvSqrt(float4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
    p0 *= norm.x;
    p1 *= norm.y;
    p2 *= norm.z;
    p3 *= norm.w;

    // Mix final noise value
    float4 m = max(0.6 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
    m = m * m;
    return 42.0 * dot(m * m, float4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

float fbm4(float3 p, float theta, float f, float lac, float r) {
    float3x3 mtx = float3x3(
        cos(theta), -sin(theta), 0.0,
        sin(theta),  cos(theta), 0.0,
        0.0,         0.0,        1.0);

    float lacunarity = lac;
    float roughness = r;
    float amp = 1.0;
    float total_amp = 0.0;

    float accum = 0.0;
    float3 X = p * f;
    for (int i = 0; i < 4; i++) {
        accum += amp * snoise(X);
        X *= (lacunarity + (snoise(X) + 0.1) * 0.006);
        X = mul(X, mtx);

        total_amp += amp;
        amp *= roughness;
    }

    return accum / total_amp;
}

float fbm8(float3 p, float theta, float f, float lac, float r) {
    float3x3 mtx = float3x3(
        cos(theta), -sin(theta), 0.0,
        sin(theta),  cos(theta), 0.0,
        0.0,         0.0,        1.0);

    float lacunarity = lac;
    float roughness = r;
    float amp = 1.0;
    float total_amp = 0.0;

    float accum = 0.0;
    float3 X = p * f;
    for (int i = 0; i < 8; i++) {
        accum += amp * snoise(X);
        X *= (lacunarity + (snoise(X) + 0.1) * 0.006);
        X = mul(X, mtx);

        total_amp += amp;
        amp *= roughness;
    }

    return accum / total_amp;
}

float turbulence(float val) {
    float n = 1.0 - abs(val);
    return n * n;
}

float pattern(in float3 p, inout float3 q, inout float3 r) {
    q.x = fbm4(p + 0.0, 0.0, 1.0, 2.0, 0.33);
    q.y = fbm4(p + 6.0, 0.0, 1.0, 2.0, 0.33);

    r.x = fbm8(p + q - 2.4, 0.0, 1.0, 3.0, 0.5);
    r.y = fbm8(p + q + 8.2, 0.0, 1.0, 3.0, 0.5);

    q.x = turbulence(q.x);
    q.y = turbulence(q.y);

    float f = fbm4(p + (1.0 * r), 0.0, 1.0, 2.0, 0.5);

    return f;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 st = fragCoord.xy / resolution.xy;
    float aspect = resolution.x / resolution.y;
    st.x *= aspect;

    float2 uv = st;

    float t = time * 0.1;

    float3 spectrum0 = float3(0.94, 0.02, 0.03);
    float3 spectrum1 = float3(0.04, 0.04, 0.22);
    float3 spectrum2 = float3(1.00, 0.80, 1.00);
    float3 spectrum3 = float3(0.20, 0.40, 0.50);

    uv -= 0.5;
    uv *= 3.5;

    float3 p = float3(uv.x, uv.y, t);
    float3 q = (float3)0.0;
    float3 r = (float3)0.0;
    float f = pattern(p, q, r);

    float3 color = (float3)0.0;
    color = lerp(spectrum1, spectrum3, pow(length(q), 4.0));
    color = lerp(color, spectrum0, pow(length(r), 1.4));
    color = lerp(color, spectrum2, f);

    color = pow(color, (float3)2.0);

    // Darken / desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
