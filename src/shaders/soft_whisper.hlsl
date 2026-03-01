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

#define TIME        (time * 3.0)
#define PI          3.141592654
#define PI_2        (0.5 * PI)
#define TAU         (2.0 * PI)

static const float hf = 0.01;

static const float4 hsv2rgb_K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);

float3 hsv2rgb(float3 c) {
    float3 p = abs(frac(c.xxx + hsv2rgb_K.xyz) * 6.0 - hsv2rgb_K.www);
    return c.z * lerp(hsv2rgb_K.xxx, clamp(p - hsv2rgb_K.xxx, 0.0, 1.0), c.y);
}

float3 HSV2RGB(float3 c) {
    return c.z * lerp(hsv2rgb_K.xxx, clamp(abs(frac(c.xxx + hsv2rgb_K.xyz) * 6.0 - hsv2rgb_K.www) - hsv2rgb_K.xxx, 0.0, 1.0), c.y);
}

float3 sRGB(float3 t) {
    float3 lo = 12.92 * t;
    float3 hi = 1.055 * pow(t, (float3)(1.0 / 2.4)) - 0.055;
    return lerp(hi, lo, step(t, (float3)0.0031308));
}

float3 aces_approx(float3 v) {
    v = max(v, 0.0);
    v *= 0.6;
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((v * (a * v + b)) / (v * (c * v + d) + e), 0.0, 1.0);
}

float tanh_approx(float x) {
    float x2 = x * x;
    return clamp(x * (27.0 + x2) / (27.0 + 9.0 * x2), -1.0, 1.0);
}

float pmin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

float pabs(float a, float k) {
    return -pmin(a, -a, k);
}

float2x2 rot(float a) {
    float s = sin(a);
    float c = cos(a);
    return float2x2(c, s, -s, c);
}

float height(float2 p) {
    float tm = TIME;
    const float xm = 0.5 * 0.005123;
    float ym = lerp(0.125, 0.25, 0.5 - 0.5 * sin(cos(TAU * TIME / 600.0)));

    p *= 0.4;

    float d = length(p);
    float c = 1E6;
    float x = pow(d, 0.1);
    float y = (atan2(p.x, p.y) + 0.05 * tm - 2.0 * d) / TAU;

    for (float i = 0.0; i < 4.0; i += 1.0) {
        float v = length(frac(float2(x - tm * i * xm, frac(y + i * ym) * 0.125) * 16.0) * 2.0 - 1.0);
        c = pmin(c, v, 0.0125);
    }

    float h = (-hf + hf * (pabs(tanh_approx(5.5 * d - 40.0 * c * c * d * d * (0.55 - d)) - 0.25 * d, 0.25)));
    return h;
}

float3 calc_normal(float2 p) {
    float2 e = float2(4.0 / resolution.y, 0.0);

    float3 n;
    n.x = height(p + e.xy) - height(p - e.xy);
    n.y = -2.0 * e.x;
    n.z = height(p + e.yx) - height(p - e.yx);

    return normalize(n);
}

float3 calc_color(float2 p) {
    const float ss = 1.0;
    const float hh = 1.95;

    float3 lp1 = -float3(1.0, hh, -1.0) * float3(ss, 1.0, ss);
    float3 lp2 = -float3(-1.0, hh, -1.0) * float3(ss, 1.0, ss);

    float3 lcol1 = HSV2RGB(float3(0.70, 0.55, 2.0));
    float3 lcol2 = HSV2RGB(float3(0.67, 0.7, 1.0));
    float3 mat_col = HSV2RGB(float3(0.55, 0.5, 0.05));
    const float spe = 7.0;

    float h = height(p);
    float3 n = calc_normal(p);

    float3 ro = float3(0.0, 8.0, 0.0);

    float3 po = float3(p.x, 0.0, p.y);
    float3 rd = normalize(ro - po);

    float3 ld1 = normalize(lp1 - po);
    float3 ld2 = normalize(lp2 - po);

    float diff1 = max(dot(n, ld1), 0.0);
    float diff2 = max(dot(n, ld2), 0.0);

    float3 rn = n;
    float3 ref_vec = reflect(rd, rn);
    float ref1 = max(dot(ref_vec, ld1), 0.0);
    float ref2 = max(dot(ref_vec, ld2), 0.0);

    float dm = tanh_approx(abs(h) * 120.0);
    float rm = dm;
    dm *= dm;

    float3 lpow1 = dm * mat_col * lcol1;
    float3 lpow2 = dm * mat_col * lcol2;

    float3 col = float3(0.0, 0.0, 0.0);
    col += diff1 * diff1 * lpow1;
    col += diff2 * diff2 * lpow2;

    col += rm * pow(ref1, spe) * lcol1;
    col += rm * pow(ref2, spe) * lcol2;

    return col;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 q = fragCoord / resolution.xy;
    float2 p = -1.0 + 2.0 * q;
    p.x *= resolution.x / resolution.y;
    float3 col = calc_color(p);

    col = aces_approx(col);
    col = sRGB(col);

    // Post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
