// CC0: Windows Terminal Damask Rose
// Original by mrange - https://www.shadertoy.com/view/flKfzh

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
#define PI_2        (0.5*PI)
#define TAU         (2.0*PI)
// GLSL mat2 is column-major; HLSL float2x2 is row-major — transposed
#define ROT(a)      float2x2(cos(a), -sin(a), sin(a), cos(a))

// Using standard atan2; uncomment FASTATAN line and switch to use atan_approx
//#define FASTATAN
#if defined(FASTATAN)
#define ATAN atan_approx
#else
#define ATAN atan2
#endif

static const float hf = 0.015;

// License: WTFPL, author: sam hocevar, found: https://stackoverflow.com/a/17897228/418488
static const float4 hsv2rgb_K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
float3 hsv2rgb(float3 c) {
    float3 p = abs(frac(c.xxx + hsv2rgb_K.xyz) * 6.0 - hsv2rgb_K.www);
    return c.z * lerp(hsv2rgb_K.xxx, clamp(p - hsv2rgb_K.xxx, 0.0, 1.0), c.y);
}
// Macro version of above to enable compile-time constants
#define HSV2RGB(c)  (c.z * lerp(hsv2rgb_K.xxx, clamp(abs(frac(c.xxx + hsv2rgb_K.xyz) * 6.0 - hsv2rgb_K.www) - hsv2rgb_K.xxx, 0.0, 1.0), c.y))

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

// License: Unknown, author: Unknown, found: don't remember
float tanh_approx(float x) {
    float x2 = x * x;
    return clamp(x * (27.0 + x2) / (27.0 + 9.0 * x2), -1.0, 1.0);
}

// License: MIT, author: Pascal Gilcher, found: https://www.shadertoy.com/view/flSXRV
float atan_approx(float y, float x) {
    float cosatan2 = x / (abs(x) + abs(y));
    float t = PI_2 - cosatan2 * PI_2;
    return y < 0.0 ? -t : t;
}

// License: MIT, author: Inigo Quilez, found: https://www.iquilezles.org/www/articles/smin/smin.htm
float pmin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

float pabs(float a, float k) {
    return -pmin(a, -a, k);
}

float height(float2 p) {
    float tm = time;
    const float xm = 0.5 * 0.005123;
    float ym = lerp(0.125, 0.25, 0.5 - 0.5 * cos(TAU * time / 600.0));

    p *= 0.4;

    float d = length(p);
    float c = 1E6;
    float x = pow(d, 0.1);
    float y = (ATAN(p.x, p.y) + 0.05 * tm - 2.0 * d) / TAU;

    for (float i = 0.0; i < 3.0; ++i) {
        float v = length(frac(float2(x - tm * i * xm, frac(y + i * ym) * 0.5) * 20.0) * 2.0 - 1.0);
        c = pmin(c, v, 0.125);
    }

    float h = (-hf + hf * (pabs(tanh_approx(5.5 * d - 80.0 * c * c * d * d * (0.55 - d)) - 0.25 * d, 0.25)));
    return h;
}

float3 get_normal(float2 p) {
    float2 e = float2(4.0 / resolution.y, 0);

    float3 n;
    n.x = height(p + e.xy) - height(p - e.xy);
    n.y = -2.0 * e.x;
    n.z = height(p + e.yx) - height(p - e.yx);

    return normalize(n);
}

float3 get_color(float2 p) {
    const float ss = 1.25;
    const float hh = 1.95;

    float3 lp1 = -float3(1.0, hh, -1.0) * float3(ss, 1.0, ss);
    float3 lp2 = -float3(-1.0, hh, -1.0) * float3(ss, 1.0, ss);

    float3 lcol1 = HSV2RGB(float3(0.30, 0.35, 2.0));
    float3 lcol2 = HSV2RGB(float3(0.57, 0.6, 2.0));
    float3 mat = HSV2RGB(float3(0.55, 0.9, 0.05));
    const float spe = 16.0;

    float h = height(p);
    float3 n = get_normal(p);

    float3 ro = float3(0.0, 8.0, 0.0);

    float3 po = float3(p.x, 0.0, p.y);
    float3 rd = normalize(ro - po);

    float3 ld1 = normalize(lp1 - po);
    float3 ld2 = normalize(lp2 - po);

    float diff1 = max(dot(n, ld1), 0.0);
    float diff2 = max(dot(n, ld2), 0.0);

    float3 rn = n;
    float3 ref = reflect(rd, rn);
    float ref1 = max(dot(ref, ld1), 0.0);
    float ref2 = max(dot(ref, ld2), 0.0);

    float dm = tanh_approx(abs(h) * 120.0);
    float rm = dm;
    dm *= dm;

    float3 lpow1 = dm * mat * lcol1;
    float3 lpow2 = dm * mat * lcol2;

    float3 col = (float3)0.0;
    col += diff1 * diff1 * lpow1;
    col += diff2 * diff2 * lpow2;

    col += rm * pow(ref1, spe) * lcol1;
    col += rm * pow(ref2, spe) * lcol2;

    return col;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 q = fragCoord / resolution;
    float2 p = -1.0 + 2.0 * q;
    p.x *= resolution.x / resolution.y;
    float3 col = get_color(p);

    col = aces_approx(col);
    col = sRGB(col);

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
