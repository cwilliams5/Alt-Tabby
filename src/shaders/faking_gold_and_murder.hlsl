// Faking Gold and Murder
//  Converted from Shadertoy: https://www.shadertoy.com/view/4tSGW3
//  Author: denzen
//  Simplex noise: Ashima Arts (MIT License)

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

/* ~~~ Ashima Simplex Noise ~~~ */

float3 mod289_3(float3 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float2 mod289_2(float2 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float3 permute(float3 x) {
    return mod289_3(((x * 34.0) + 1.0) * x);
}

float snoise(float2 v) {
    const float4 C = float4(0.211324865405187,
                            0.366025403784439,
                           -0.577350269189626,
                            0.024390243902439);
    // First corner
    float2 i  = floor(v + dot(v, C.yy));
    float2 x0 = v -   i + dot(i, C.xx);

    // Other corners
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;

    // Permutations
    i = mod289_2(i);
    float3 p = permute(permute(i.y + float3(0.0, i1.y, 1.0))
                                    + i.x + float3(0.0, i1.x, 1.0));

    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;

    // Gradients
    float3 x_ = 2.0 * frac(p * C.www) - 1.0;
    float3 h = abs(x_) - 0.5;
    float3 ox = floor(x_ + 0.5);
    float3 a0 = x_ - ox;

    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);

    float3 g;
    g.x  = a0.x  * x0.x  + h.x  * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

/* ~~~ End Simplex Noise ~~~ */

#define NB_OCTAVES 6
#define LACUNARITY 2.0
#define GAIN 0.5

float fbm(float2 p) {
    float total = 0.0;
    float frequency = 1.0;
    float amplitude = 1.0;

    for (int i = 0; i < NB_OCTAVES; i++) {
        total += snoise(p * frequency) * amplitude;
        frequency *= LACUNARITY;
        amplitude *= GAIN;
    }
    return total;
}

static float s_c1, s_c2;

float pattern(float2 p, out float c) {
    float t = time;
    float2 q = float2(fbm(p + float2(0.0, 0.0)),
                       fbm(p + float2(s_c2 * 0.1, t * 0.02)));

    c = fbm(p + 2.0 * q + float2(s_c1 + s_c2, -t * 0.01));
    return fbm(p + 2.0 * q);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord.xy / resolution.xy;
    float t = time;

    s_c1 = 0.1 + cos(t * 0.01) * 0.9;
    s_c2 = 0.4 + cos(t * 0.06) * 0.4;

    float2 p = float2(uv.x + s_c1 * 0.4 + s_c2 * 0.6, uv.y * 0.3);
    p.x *= 0.4 + s_c2 * 0.4;

    float c;
    float3 col = (float3)pattern(p, c);
    col.r = 0.6 + lerp(col.x, c, 0.2);
    col.b = 0.2 + lerp(col.x, c, 0.5) * 0.1;

    // Darken/desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, (float3)lum, desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
