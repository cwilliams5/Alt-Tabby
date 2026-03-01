// Turbulence Texture — abs(perlin) fbm
// https://www.shadertoy.com/view/ssj3Wc
// Author: penghuailiang | License: CC BY-NC-SA 3.0

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

float3 random_perlin(float3 p) {
    p = float3(
            dot(p, float3(127.1, 311.7, 69.5)),
            dot(p, float3(269.5, 183.3, 132.7)),
            dot(p, float3(247.3, 108.5, 96.5)));
    return -1.0 + 2.0 * frac(sin(p) * 43758.5453123);
}

float noise_perlin(float3 p) {
    float3 i = floor(p);
    float3 s = frac(p);

    float a = dot(random_perlin(i), s);
    float b = dot(random_perlin(i + float3(1, 0, 0)), s - float3(1, 0, 0));
    float c = dot(random_perlin(i + float3(0, 1, 0)), s - float3(0, 1, 0));
    float d = dot(random_perlin(i + float3(0, 0, 1)), s - float3(0, 0, 1));
    float e = dot(random_perlin(i + float3(1, 1, 0)), s - float3(1, 1, 0));
    float f = dot(random_perlin(i + float3(1, 0, 1)), s - float3(1, 0, 1));
    float g = dot(random_perlin(i + float3(0, 1, 1)), s - float3(0, 1, 1));
    float h = dot(random_perlin(i + float3(1, 1, 1)), s - float3(1, 1, 1));

    float3 u = smoothstep(0.0, 1.0, s);

    return lerp(lerp(lerp(a, b, u.x),
                lerp(c, e, u.x), u.y),
            lerp(lerp(d, f, u.x),
                lerp(g, h, u.x), u.y), u.z);
}

float noise_turbulence(float3 p)
{
    float f = 0.0;
    float a = 1.0;
    p = 4.0 * p;
    for (int i = 0; i < 5; i++) {
        f += a * abs(noise_perlin(p));
        p = 2.0 * p;
        a /= 2.0;
    }
    return f;
}

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord / resolution;

    float c1 = noise_turbulence(float3(1.0 * uv, time / 10.0));
    float3 col = float3(1.5 * c1, 1.5 * c1 * c1 * c1, c1 * c1 * c1 * c1 * c1 * c1);

    // darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}