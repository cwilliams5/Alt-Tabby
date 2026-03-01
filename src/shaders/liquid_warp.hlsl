// Liquid Warp — domain warping based on iq's notes
// https://www.shadertoy.com/view/wtXXD2
// Author: whoadrian | License: CC BY-NC-SA 3.0

cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};

Texture2D iChannel0 : register(t0);
SamplerState samp0 : register(s0);

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

// NOISE ////

float noise(in float2 x)
{
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

float fbm(float2 p)
{
    float f = 0.0;

    f += 0.500000 * noise(p); p = mul(mtx, p) * 2.02;
    f += 0.250000 * noise(p); p = mul(mtx, p) * 2.03;
    f += 0.125000 * noise(p); p = mul(mtx, p) * 2.01;
    f += 0.062500 * noise(p); p = mul(mtx, p) * 2.04;
    f += 0.031250 * noise(p); p = mul(mtx, p) * 2.01;
    f += 0.015625 * noise(p);

    return f / 0.96875;
}

// -----------------------------------------------------------------------

float pattern(in float2 p, in float t, in float2 uv, out float2 q, out float2 r, out float2 g)
{
    q = float2(fbm(p), fbm(p + float2(10, 1.3)));

    r = float2(fbm(p + 4.0 * q + float2(t, t) + float2(1.7, 9.2)), fbm(p + 4.0 * q + float2(t, t) + float2(8.3, 2.8)));
    g = float2(fbm(p + 2.0 * r + float2(t * 20.0, t * 20.0) + float2(2, 6)), fbm(p + 2.0 * r + float2(t * 10.0, t * 10.0) + float2(5, 3)));
    return fbm(p + 5.5 * g + float2(-t * 7.0, -t * 7.0));
}

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = input.pos.xy;

    // Normalized pixel coordinates (from 0 to 1)
    float2 uv = fragCoord / resolution;

    // noise
    float2 q, r, g;
    float n = pattern(fragCoord * float2(0.004, 0.004), time * 0.007, uv, q, r, g);

    // base color based on main noise
    float3 col = lerp(float3(0.1, 0.4, 0.4), float3(0.5, 0.7, 0.0), smoothstep(0.0, 1.0, n));

    // other lower-octave colors and mixes
    col = lerp(col, float3(0.35, 0.0, 0.1), dot(q, q) * 1.0);
    col = lerp(col, float3(0, 0.2, 1), 0.2 * g.y * g.y);
    col = lerp(col, float3(0.3, 0, 0), smoothstep(0.0, 0.6, 0.6 * r.y * r.y));
    col = lerp(col, float3(0, 0.5, 0), 0.1 * g.x);

    // some dark outlines/contrast and different steps
    col = lerp(col, float3(0, 0, 0), smoothstep(0.3, 0.5, n) * smoothstep(0.5, 0.3, n));
    col = lerp(col, float3(0, 0, 0), smoothstep(0.7, 0.8, n) * smoothstep(0.8, 0.7, n));

    // contrast
    col *= n * 2.0;

    // vignette
    col *= 0.70 + 0.65 * sqrt(70.0 * uv.x * uv.y * (1.0 - uv.x) * (1.0 - uv.y));

    // darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}