// Pretty Colors — fbm warp inspired by IQ
// https://www.shadertoy.com/view/MtcXDr
// Author: anprogrammer | License: CC BY-NC-SA 3.0

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

#define N_DELTA 0.015625

float rand(float3 n) {
    return frac(sin(dot(n, float3(95.43583, 93.323197, 94.993431))) * 65536.32);
}

float perlin2(float3 n)
{
    float3 base = floor(n / N_DELTA) * N_DELTA;
    float3 dd = float3(N_DELTA, 0.0, 0.0);
    float
        tl = rand(base + dd.yyy),
        tr = rand(base + dd.xyy),
        bl = rand(base + dd.yxy),
        br = rand(base + dd.xxy);
    float3 p = (n - base) / dd.xxx;
    float t = lerp(tl, tr, p.x);
    float b = lerp(bl, br, p.x);
    return lerp(t, b, p.y);
}

float perlin3(float3 n)
{
    float3 base = float3(n.x, n.y, floor(n.z / N_DELTA) * N_DELTA);
    float3 dd = float3(N_DELTA, 0.0, 0.0);
    float3 p = (n - base) / dd.xxx;
    float front = perlin2(base + dd.yyy);
    float back = perlin2(base + dd.yyx);
    return lerp(front, back, p.z);
}

float fbm(float3 n)
{
    float total = 0.0;
    float m1 = 1.0;
    float m2 = 0.1;
    for (int i = 0; i < 5; i++)
    {
        total += perlin3(n * m1) * m2;
        m2 *= 2.0;
        m1 *= 0.5;
    }
    return total;
}

float nebula1(float3 uv)
{
    float n1 = fbm(uv * 2.9 - 1000.0);
    float n2 = fbm(uv + n1 * 0.05);
    return n2;
}

float nebula2(float3 uv)
{
    float n1 = fbm(uv * 1.3 + 115.0);
    float n2 = fbm(uv + n1 * 0.35);
    return fbm(uv + n2 * 0.17);
}

float nebula3(float3 uv)
{
    float n1 = fbm(uv * 3.0);
    float n2 = fbm(uv + n1 * 0.15);
    return n2;
}

float3 nebula(float3 uv)
{
    uv *= 10.0;
    return nebula1(uv * 0.5) * float3(1.0, 0.0, 0.0) +
           nebula2(uv * 0.4) * float3(0.0, 1.0, 0.0) +
           nebula3(uv * 0.6) * float3(0.0, 0.0, 1.0);
}

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = input.pos.xy;

    float size = max(resolution.x, resolution.y);
    float2 xy = (fragCoord - resolution * 0.5) / size * 2.0;
    float2 uv = xy * 0.5 + 0.5;

    float3 col = nebula(float3(uv * 5.1, time * 0.1) * 0.1) - 1.0;

    // darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    a = saturate(a);
    return float4(col * a, a);
}