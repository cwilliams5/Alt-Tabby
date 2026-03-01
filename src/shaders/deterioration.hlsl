// Deterioration - converted from Shadertoy (3dBSW3)
// Author: Blokatt - License: CC BY-NC-SA 3.0

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

float2x2 rot(float a) {
    return float2x2(
        cos(a), -sin(a),
        sin(a), cos(a));
}

float rand(float2 uv) {
    return frac(sin(dot(float2(12.9898, 78.233), uv)) * 43758.5453123);
}

float valueNoise(float2 uv) {
    float2 i = frac(uv);
    float2 f = floor(uv);
    float a = rand(f);
    float b = rand(f + float2(1.0, 0.0));
    float c = rand(f + float2(0.0, 1.0));
    float d = rand(f + float2(1.0, 1.0));
    return lerp(lerp(a, b, i.x), lerp(c, d, i.x), i.y);
}

float fbm(float2 uv) {
    float v = 0.0;
    float amp = 0.75;
    float z = (20.0 * sin(time * 0.2)) + 30.0;

    for (int i = 0; i < 10; ++i) {
        v += valueNoise(uv + (z * uv * 0.05) + (time * 0.1)) * amp;
        uv *= 3.25;
        amp *= 0.5;
    }

    return v;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 uv = fragCoord / resolution.xy - 0.5;
    float2 oldUV = uv;
    uv.x *= resolution.x / resolution.y;
    float2x2 r = rot(time * 0.02);
    uv = mul(uv, r);
    float2x2 angle = rot(fbm(uv));

    float3 col = float3(
        fbm(mul(angle, float2(5.456, -2.8112)) + uv),
        fbm(mul(angle, float2(5.476, -2.8122)) + uv),
        fbm(mul(angle, float2(5.486, -2.8132)) + uv));
    col -= smoothstep(0.1, 1.0, length(oldUV));

    // Darken / desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
