// BMtest2 by thebtype
// Ported from https://www.shadertoy.com/view/NtdyRj
// Domain warping based on IQ's warp tutorial

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

Texture2D iChannel0 : register(t0);
SamplerState samp0 : register(s0);

float noise_val(float2 x) {
    float2 p = floor(x);
    float2 f = frac(x);
    f = f * f * (3.0 - 2.0 * f);
    float a = iChannel0.SampleLevel(samp0, (p + float2(0.5, 0.5)) / 256.0, 0.0).x;
    float b = iChannel0.SampleLevel(samp0, (p + float2(1.5, 0.5)) / 256.0, 0.0).x;
    float c = iChannel0.SampleLevel(samp0, (p + float2(0.5, 1.5)) / 256.0, 0.0).x;
    float d = iChannel0.SampleLevel(samp0, (p + float2(1.5, 1.5)) / 256.0, 0.0).x;
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

static const float2x2 mtx = float2x2(0.80, 0.60, -0.60, 0.80);

float fbm(float2 p) {
    float f = 0.0;
    f += 0.500000 * noise_val(p); p = mul(p, mtx) * 2.02;
    f += 0.250000 * noise_val(p); p = mul(p, mtx) * 2.03;
    f += 0.125000 * noise_val(p); p = mul(p, mtx) * 2.01;
    f += 0.062500 * noise_val(p); p = mul(p, mtx) * 2.04;
    f += 0.031250 * noise_val(p); p = mul(p, mtx) * 2.01;
    f += 0.015625 * noise_val(p);
    return f / 0.96875;
}

float pattern(float2 p, float t, float2 uv, out float2 q, out float2 r, out float2 g) {
    q = float2(fbm(p), fbm(p + float2(10, 1.3)));
    r = float2(fbm(p + 4.0 * q + (float2)t + float2(1.7, 9.2)),
               fbm(p + 4.0 * q + (float2)t + float2(8.3, 2.8)));
    g = float2(fbm(p + 2.0 * r + (float2)(t * 20.0) + float2(2, 6)),
               fbm(p + 2.0 * r + (float2)(t * 10.0) + float2(5, 3)));
    return fbm(p + 5.5 * g + (float2)(-t * 7.0));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord / resolution;

    float2 q, r, g;
    float n = pattern(fragCoord * (float2)0.004, time * 0.007, uv, q, r, g);

    // Base color from main noise
    float3 col = lerp(float3(0.1, 0.4, 0.4), float3(0.5, 0.7, 0.0), smoothstep(0.0, 1.0, n));

    // Lower-octave color mixes
    col = lerp(col, float3(0.35, 0.0, 0.1), dot(q, q));
    col = lerp(col, float3(0, 0.2, 1), 0.2 * g.y * g.y);
    col = lerp(col, float3(0.3, 0, 0), smoothstep(0.0, 0.6, 0.6 * r.g * r.g));
    col = lerp(col, float3(0, 0.5, 0), 0.1 * g.x);

    // Dark outlines / contrast bands
    col = lerp(col, (float3)0, smoothstep(0.3, 0.5, n) * smoothstep(0.5, 0.3, n));
    col = lerp(col, (float3)0, smoothstep(0.7, 0.8, n) * smoothstep(0.8, 0.7, n));

    // Contrast
    col *= n * 2.0;

    // Vignette
    col *= 0.70 + 0.65 * sqrt(70.0 * uv.x * uv.y * (1.0 - uv.x) * (1.0 - uv.y));

    // Post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, (float3)lum, desaturate);
    col *= 1.0 - darken;

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
