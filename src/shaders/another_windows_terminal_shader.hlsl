// CC0: Another windows terminal shader
//  Created this based on an old shader as a background in windows terminal
//  Original: https://www.shadertoy.com/view/DdSGzy by mrange

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

#define PI          3.141592654
#define TAU         (2.0*PI)
#define ROT(a)      float2x2(cos(a), sin(a), -sin(a), cos(a))

// License: WTFPL, author: sam hocevar, found: https://stackoverflow.com/a/17897228/418488
static const float4 hsv2rgb_K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
float3 hsv2rgb(float3 c) {
    float3 p = abs(frac(c.xxx + hsv2rgb_K.xyz) * 6.0 - hsv2rgb_K.www);
    return c.z * lerp(hsv2rgb_K.xxx, clamp(p - hsv2rgb_K.xxx, 0.0, 1.0), c.y);
}
// Macro version of above to enable compile-time constants
#define HSV2RGB(c)  (c.z * lerp(hsv2rgb_K.xxx, clamp(abs(frac(c.xxx + hsv2rgb_K.xyz) * 6.0 - hsv2rgb_K.www) - hsv2rgb_K.xxx, 0.0, 1.0), c.y))

static const float2x2 rot0 = ROT(0.0);
static float2x2 g_rot0;
static float2x2 g_rot1;

// License: Unknown, author: nmz (twitter: @stormoid), found: https://www.shadertoy.com/view/NdfyRM
float3 sRGB(float3 t) {
    return lerp(1.055 * pow(t, (float3)(1.0 / 2.4)) - 0.055, 12.92 * t, step(t, (float3)0.0031308));
}

// License: Unknown, author: Matt Taylor (https://github.com/64), found: https://64.github.io/tonemapping/
float3 aces_approx(float3 v) {
    v = max(v, 0.0);
    v *= 0.6f;
    float a = 2.51f;
    float b = 0.03f;
    float c = 2.43f;
    float d = 0.59f;
    float e = 0.14f;
    return clamp((v * (a * v + b)) / (v * (c * v + d) + e), 0.0f, 1.0f);
}

float apolloian(float3 p, float s) {
    float scale = 1.0;
    for (int i = 0; i < 5; ++i) {
        p = -1.0 + 2.0 * frac(0.5 * p + 0.5);
        float r2 = dot(p, p);
        float k = s / r2;
        p *= k;
        scale *= k;
    }

    float3 ap = abs(p / scale);
    float d = length(ap.xy);
    d = min(d, ap.z);

    return d;
}

float df(float2 p) {
    float fz = lerp(0.75, 1.0, smoothstep(-0.9, 0.9, cos(TAU * time / 300.0)));
    float z = 1.55 * fz;
    p /= z;
    float3 p3 = float3(p, 0.1);
    p3.xz = mul(p3.xz, g_rot0);
    p3.yz = mul(p3.yz, g_rot1);
    float d = apolloian(p3, 1.0 / fz);
    d *= z;
    return d;
}

float3 effect(float2 p, float2 pp) {
    g_rot0 = ROT(0.1 * time);
    g_rot1 = ROT(0.123 * time);

    float aa = 2.0 / resolution.y;

    float d = df(p);
    float3 bcol0 = HSV2RGB(float3(0.55, 0.85, 0.85));
    float3 bcol1 = HSV2RGB(float3(0.33, 0.85, 0.025));
    float3 col = 0.1 * bcol0;
    col += bcol1 / sqrt(abs(d));
    col += bcol0 * smoothstep(aa, -aa, (d - 0.001));

    col *= smoothstep(1.5, 0.5, length(pp));

    return col;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 q = fragCoord / resolution.xy;
    float2 p = -1.0 + 2.0 * q;
    float2 pp = p;
    p.x *= resolution.x / resolution.y;
    float3 col = effect(p, pp);
    col = aces_approx(col);
    col = sqrt(col);

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
