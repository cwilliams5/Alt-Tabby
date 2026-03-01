// Satinlike (Simple FBM Warp) by CaliCoastReplay
// Ported from https://www.shadertoy.com/view/ll3GD7
// FBM domain warping inspired by IQ's warp tutorial

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

// Color space helpers

float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = lerp(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = lerp(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(frac(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * lerp(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

// FBM (Fractal Brownian Motion)

float rand_val(float2 n) {
    return frac(cos(dot(n, float2(12.9898, 4.1414))) * 3758.5453);
}

float noise_val(float2 n) {
    float2 d = float2(0.0, 1.0);
    float2 b = floor(n);
    float2 f = smoothstep((float2)0, (float2)1, frac(n));
    return lerp(lerp(rand_val(b), rand_val(b + d.yx), f.x),
                lerp(rand_val(b + d.xy), rand_val(b + d.yy), f.x), f.y);
}

float fbm(float2 n) {
    float total = 0.0;
    float amplitude = 1.0;
    [loop]
    for (int i = 0; i < 10; i++) {
        total += noise_val(n) * amplitude;
        amplitude *= 0.4;
    }
    return total;
}

float pattern(float2 p) {
    float2 q = float2(
        fbm(p),
        fbm(p + float2(5.2 + sin(time) / 10.0, 1.3 - cos(time) / 10.0)));

    float2 r = float2(
        fbm(p + 4.0 * q + float2(1.7 + sin(time) / 10.0, 9.2)),
        fbm(p + 4.0 * q + float2(8.3, 2.8 - cos(time) / 10.0)));

    float2 ac = p + 4.0 * r;
    ac.x += sin(time);
    ac.y += cos(time);
    return sqrt(pow(fbm(ac + time
               + fbm(ac - time
                    + fbm(ac + sin(time)))), -2.0));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord / resolution;
    float intensity = pattern(uv);
    float3 color = float3(uv, 0.5 + 0.5 * sin(time));
    float3 hsv = rgb2hsv(color);
    hsv.z = cos(hsv.y) - 0.1;
    color = hsv2rgb(hsv);
    color *= intensity;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, (float3)lum, desaturate);
    color *= 1.0 - darken;

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
