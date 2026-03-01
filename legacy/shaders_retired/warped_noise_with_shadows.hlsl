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

#define CONT 0.1
#define MOD3 float3(.1031, .11369, .13787)

float r_f(float n)
{
    return frac(cos(n * 89.42) * 343.42);
}

float2 r_v(float2 n)
{
    return float2(r_f(n.x * 23.62 - 300.0 + n.y * 34.35), r_f(n.x * 45.13 + 256.0 + n.y * 38.89));
}

float worley(float2 n, float s)
{
    float dis = 2.0;
    for (int x = -1; x <= 1; x++)
    {
        for (int y = -1; y <= 1; y++)
        {
            float2 p = floor(n / s) + float2(x, y);
            float d = length(r_v(p) + float2(x, y) - frac(n / s));
            if (dis > d)
            {
                dis = d;
            }
        }
    }
    return 1.0 - dis;
}

float3 hash33(float3 p3)
{
    p3 = frac(p3 * MOD3);
    p3 += dot(p3, p3.yxz + 19.19);
    return -1.0 + 2.0 * frac(float3((p3.x + p3.y) * p3.z, (p3.x + p3.z) * p3.y, (p3.y + p3.z) * p3.x));
}

float perlin_noise(float3 p)
{
    float3 pi = floor(p);
    float3 pf = p - pi;

    float3 w = pf * pf * (3.0 - 2.0 * pf);

    return lerp(
            lerp(
                lerp(dot(pf - float3(0, 0, 0), hash33(pi + float3(0, 0, 0))),
                     dot(pf - float3(1, 0, 0), hash33(pi + float3(1, 0, 0))),
                     w.x),
                lerp(dot(pf - float3(0, 0, 1), hash33(pi + float3(0, 0, 1))),
                     dot(pf - float3(1, 0, 1), hash33(pi + float3(1, 0, 1))),
                     w.x),
                w.z),
            lerp(
                lerp(dot(pf - float3(0, 1, 0), hash33(pi + float3(0, 1, 0))),
                     dot(pf - float3(1, 1, 0), hash33(pi + float3(1, 1, 0))),
                     w.x),
                lerp(dot(pf - float3(0, 1, 1), hash33(pi + float3(0, 1, 1))),
                     dot(pf - float3(1, 1, 1), hash33(pi + float3(1, 1, 1))),
                     w.x),
                w.z),
            w.y);
}

float noise(float2 v)
{
    float dis = (1.0 + perlin_noise(float3(v, sin(time * 0.15)) * 5.0))
        * (1.0 + (worley(v, 32.0) +
        0.5 * worley(2.0 * v, 32.0) +
        0.25 * worley(4.0 * v, 32.0)));

    return dis * 0.25;
}

float frct(float2 v)
{
    return noise(v + noise(v - noise(v)));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float c = (frct(fragCoord / resolution) - frct((fragCoord + CONT) / resolution)) / CONT + 0.5;

    float3 color = (float3)abs(sqrt(c));

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness — premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}