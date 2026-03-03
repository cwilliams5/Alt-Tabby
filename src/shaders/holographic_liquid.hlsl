// Holographic liquid — dennizor (Shadertoy 4fs3Rl)
// CC BY-NC-SA 3.0
// Converted from GLSL to HLSL for Alt-Tabby
// Domain warping based on https://iquilezles.org/articles/warp/warp.htm

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

float noise(float2 x) {
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

    f += 0.500000 * noise(p); p = mul(p, mtx) * 2.02;
    f += 0.250000 * noise(p); p = mul(p, mtx) * 2.03;
    f += 0.125000 * noise(p); p = mul(p, mtx) * 2.01;
    f += 0.062500 * noise(p); p = mul(p, mtx) * 2.04;
    f += 0.031250 * noise(p); p = mul(p, mtx) * 2.01;
    f += 0.015625 * noise(p);

    return f / 0.96875;
}

struct PatternResult {
    float value;
    float2 q;
    float2 r;
    float2 g;
};

PatternResult pattern(float2 p, float t, float2 uv) {
    PatternResult res;
    res.q = float2(fbm(p), fbm(p + float2(10, 1.3)));

    res.r = float2(fbm(p + 4.0 * res.q + (float2)t + float2(1.7, 9.2)),
                   fbm(p + 4.0 * res.q + (float2)t + float2(8.3, 2.8)));
    res.g = float2(fbm(p + 2.0 * res.r + float2(t * 20.0, t * 20.0) + float2(2, 6)),
                   fbm(p + 2.0 * res.r + float2(t * 10.0, t * 10.0) + float2(5, 3)));
    res.value = fbm(p + 5.5 * res.g + float2(-t * 7.0, -t * 7.0));
    return res;
}

float3 getGradientColor(float t) {
    float3 color1 = float3(255.0, 199.0, 51.0) / 255.0;
    float3 color2 = float3(245.0, 42.0, 116.0) / 255.0;
    float3 color3 = float3(7.0, 49.0, 143.0) / 255.0;
    float3 color4 = float3(71.0, 205.0, 255.0) / 255.0;
    float3 color5 = float3(185.0, 73.0, 255.0) / 255.0;
    float3 color6 = float3(255.0, 180.0, 204.0) / 255.0;

    float ratio1 = 0.1;
    float ratio2 = 0.3;
    float ratio3 = 0.6;
    float ratio4 = 0.8;

    if (t < ratio1)
        return lerp(color1, color2, t / ratio1);
    else if (t < ratio2)
        return lerp(color2, color3, (t - ratio1) / (ratio2 - ratio1));
    else if (t < ratio3)
        return lerp(color3, color4, (t - ratio2) / (ratio3 - ratio2));
    else if (t < ratio4)
        return lerp(color4, color5, (t - ratio3) / (ratio4 - ratio3));
    else
        return lerp(color5, color6, (t - ratio4) / (1.0 - ratio4));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float zoom = 0.05;
    float speed = 0.2;
    float2 zoomedCoord = fragCoord * zoom;
    float adjustedTime = time * speed;
    float2 uv = zoomedCoord / resolution.xy;

    PatternResult pat = pattern(zoomedCoord * (float2)0.004, adjustedTime * 0.007, uv);

    float t = frac(pat.value * 2.6 - 1.0);
    float3 col = getGradientColor(t);

    col *= 0.5 + 0.5 * pow(16.0 * uv.x * uv.y * (1.0 - uv.x) * (1.0 - uv.y), 0.1);

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, (float3)lum, desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
