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

float hash21(float2 v) {
    return frac(sin(dot(v, float2(12.9898, 78.233))) * 43758.5453123);
}

float noise(float2 uv) {
    float2 f = frac(uv);
    float2 i = floor(uv);
    f = f * f * (3.0 - 2.0 * f);
    return lerp(
        lerp(hash21(i), hash21(i + float2(1, 0)), f.x),
        lerp(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), f.x), f.y);
}

float fbm(float2 uv) {
    float freq = 2.0;
    float amp = 0.5;
    float gain = 0.54;
    float v = 0.0;
    for (int i = 0; i < 6; ++i) {
        v += amp * noise(uv);
        amp *= gain;
        uv *= freq;
    }
    return v;
}

float fbmPattern(float2 p, out float2 q, out float2 r) {
    float qCoef = 2.0;
    float rCoef = 3.0;
    q.x = fbm(p              + 0.0  * time);
    q.y = fbm(p              - 0.02 * time + float2(10.0, 7.36));
    r.x = fbm(p + qCoef * q  + 0.1  * time + float2(5.0, 3.0));
    r.y = fbm(p + qCoef * q  - 0.07 * time + float2(10.0, 7.36));
    return fbm(p + rCoef * r  + 0.1  * time);
}

float3 basePalette(float t) {
    return 0.5 + 0.6 * cos(6.283185 * (-t + float3(0.0, 0.1, 0.2) - 0.2));
}

float3 smokePalette(float t) {
    return float3(0.6, 0.5, 0.5)
        + 0.5 * cos(6.283185 * (-float3(1.0, 1.0, 0.5) * t + float3(0.2, 0.15, -0.1) - 0.2));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord / resolution.yy;

    float scale = 5.0;
    float3 col = (float3)0.1;

    float2 q;
    float2 r;
    float n = fbmPattern(scale * uv, q, r);
    float3 baseCol = basePalette(r.x);
    float3 smokeCol = smokePalette(n);

    col = lerp(baseCol, smokeCol, pow(q.y, 1.3));

    // Apply darken/desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
