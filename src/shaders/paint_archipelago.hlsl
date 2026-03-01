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

float hash(float2 p) { return frac(1e4 * sin(17.0 * p.x + p.y * 0.1) * (0.1 + abs(sin(p.y * 13.0 + p.x)))); }

float noise(float2 x) {
    float2 i = floor(x);
    float2 f = frac(x);
    float a = hash(i);
    float b = hash(i + float2(1.0, 0.0));
    float c = hash(i + float2(0.0, 1.0));
    float d = hash(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return lerp(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

#define octaves 14

float fbm(in float2 p) {
    float value = 0.0;
    float freq = 1.0;
    float amp = 0.5;

    for (int i = 0; i < octaves; i++) {
        value += amp * (noise((p - (float2)1.0) * freq));
        freq *= 1.9;
        amp *= 0.6;
    }
    return value;
}

float pattern(in float2 p) {
    float2 aPos = float2(sin(time * 0.005), sin(time * 0.01)) * 6.0;
    float2 aScale = (float2)3.0;
    float a = fbm(p * aScale + aPos);

    float2 bPos = float2(sin(time * 0.01), sin(time * 0.01)) * 1.0;
    float2 bScale = (float2)0.6;
    float b = fbm((p + a) * bScale + bPos);

    float2 cPos = float2(-0.6, -0.5) + float2(sin(-time * 0.001), sin(time * 0.01)) * 2.0;
    float2 cScale = (float2)2.6;
    float c = fbm((p + b) * cScale + cPos);
    return c;
}

float3 palette(in float t) {
    float3 a = float3(0.5, 0.5, 0.5);
    float3 b = float3(0.45, 0.25, 0.14);
    float3 c = float3(1.0, 1.0, 1.0);
    float3 d = float3(0.0, 0.1, 0.2);
    return a + b * cos(6.28318 * (c * t + d));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 p = fragCoord.xy / resolution.xy;
    p.x *= resolution.x / resolution.y;
    float value = pow(pattern(p), 2.0);
    float3 color = palette(value);

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}