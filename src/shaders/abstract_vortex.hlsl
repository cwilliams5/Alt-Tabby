// Abstract Vortex by Frostbyte_ — https://www.shadertoy.com/view/wcyBD3
// Low raymarch count volumetric vortex (CC BY-NC-SA 4.0)

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

// 2D rotation matrix
// GLSL mat2(c,-s,s,c)*v → HLSL mul(v, float2x2(c,-s,s,c))
float2 rot2d(float2 v, float t) {
    float s = sin(t), c = cos(t);
    return mul(v, float2x2(c, -s, s, c));
}

// ACES tonemap
// GLSL M*v → HLSL mul(v, M) for same constructor args
float3 acesTonemap(float3 c) {
    static const float3x3 m1 = float3x3(
        0.59719, 0.07600, 0.02840,
        0.35458, 0.90834, 0.13383,
        0.04823, 0.01566, 0.83777);
    static const float3x3 m2 = float3x3(
        1.60475, -0.10208, -0.00327,
        -0.53108, 1.10813, -0.07276,
        -0.07367, -0.00605, 1.07602);
    float3 v = mul(c, m1);
    float3 a = v * (v + 0.0245786) - 0.000090537;
    float3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
    return mul(a / b, m2);
}

// Xor's Dot Noise
float dotNoise(float3 p) {
    static const float PHI = 1.618033988;
    static const float3x3 GOLD = float3x3(
        -0.571464913, +0.814921382, +0.096597072,
        -0.278044873, -0.303026659, +0.911518454,
        +0.772087367, +0.494042493, +0.399753815);
    // GLSL: GOLD*p (M*v) → HLSL: mul(p, GOLD)
    // GLSL: p*GOLD (v*M) → HLSL: mul(GOLD, p)
    return dot(cos(mul(p, GOLD)), sin(mul(GOLD, PHI * p)));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float t = time;
    float3 p = float3(0.0, 0.0, t);
    float3 l = (float3)0;
    float3 d = normalize(float3(2.0 * fragCoord - resolution, resolution.y));

    [unroll]
    for (float i = 0.0; i < 10.0; i++) {
        float3 b = p;
        b.xy = rot2d(sin(b.xy), t * 1.5 + b.z * 3.0);
        float s = 0.001 + abs(dotNoise(b * 12.0) / 12.0 - dotNoise(b)) * 0.4;
        s = max(s, 2.0 - length(p.xy));
        s += abs(p.y * 0.75 + sin(p.z + t * 0.1 + p.x * 1.5)) * 0.2;
        p += d * s;
        l += (1.0 + sin(i + length(p.xy * 0.1) + float3(3, 1.5, 1))) / s;
    }

    float3 color = acesTonemap(l * l / 6e2);

    // Apply darken/desaturate
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float alpha = max(color.r, max(color.g, color.b));
    return float4(color * alpha, alpha);
}
