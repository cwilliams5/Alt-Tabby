// Abstract Painting
//  Converted from Shadertoy: https://www.shadertoy.com/view/4dVfW3
//  Author: FlorianDuf
//  Inspired by: https://iquilezles.org/articles/warp & https://thebookofshaders.com/

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

#define OCTAVES 5

float rand(float2 st)
{
    return frac(sin(dot(st,
                        float2(12.9898, 78.233))) *
        43758.5453123);
}

float noise(float2 st) {
    float2 i = floor(st);
    float2 f = frac(st);

    // Four corners in 2D of a tile
    float a = rand(i);
    float b = rand(i + float2(1.0, 0.0));
    float c = rand(i + float2(0.0, 1.0));
    float d = rand(i + float2(1.0, 1.0));

    float2 u = smoothstep(0.0, 1.0, f);

    return lerp(a, b, u.x) +
            (c - a) * u.y * (1.0 - u.x) +
            (d - b) * u.x * u.y;
}

float fbm(float2 st) {
    float value = 0.0;
    float amplitude = 0.5;

    for (int i = 0; i < OCTAVES; i++) {
        value += amplitude * noise(st);
        st *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

float pattern(float2 p, out float2 q, out float2 r)
{
    q.x = fbm(p + float2(0.0, 0.0));
    q.y = fbm(p + float2(5.2, 1.3));

    q += float2(sin(time * 0.25), sin(time * 0.3538));

    r.x = fbm(p + 4.0 * q + float2(1.7, 9.2));
    r.y = fbm(p + 4.0 * q + float2(8.3, 2.8));

    r += float2(sin(time * 0.125), sin(time * 0.43538));

    return fbm(p + 4.0 * r);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = 10.0 * fragCoord / resolution.x;

    float2 q, r;
    float val = pattern(uv, q, r);
    float3 col = (float3)0.0;

    // TYPE 0: art effect
    col = lerp(float3(q * 0.1, 0.0), float3(r, 0.5 * sin(time) + 0.5), val);

    // Darken/desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, (float3)lum, desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
