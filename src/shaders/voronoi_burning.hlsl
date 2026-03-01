// Domain warping applied to Voronoi noise
// Written by Claus O. Wilke, 2022 (MIT License)
// Noise functions adapted from Inigo Quilez (MIT License)
// Converted from https://www.shadertoy.com/view/NdtcRr

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

// ACES tone mapping (from Common tab)
float3 s_curve(float3 x)
{
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    x = max(x, 0.0);
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

// voronoi smoothness
static const float voronoi_smooth = 0.05;

float hash(float2 p)
{
    int2 texp = int2(
        int(fmod(p.x, 256.0)),
        int(fmod(p.y, 256.0)));

    return -1.0 + 2.0 * iChannel0.Load(int3(texp, 0)).x;
}

float2 hash2(float2 p)
{
    return float2(hash(p), hash(p + float2(32.0, 18.0)));
}

// value noise (Inigo Quilez, MIT License)
float noise1(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);

    float2 u = f * f * (3.0 - 2.0 * f);

    return lerp(lerp(hash(i + float2(0.0, 0.0)),
                     hash(i + float2(1.0, 0.0)), u.x),
                lerp(hash(i + float2(0.0, 1.0)),
                     hash(i + float2(1.0, 1.0)), u.x), u.y);
}

// voronoi (Inigo Quilez, MIT License)
float voronoi(float2 x, float w)
{
    float2 n = floor(x);
    float2 f = frac(x);

    float dout = 8.0;
    for (int j = -2; j <= 2; j++)
    for (int i = -2; i <= 2; i++)
    {
        float2 g = float2((float)i, (float)j);
        float2 o = 0.5 + 0.5 * hash2(n + g);

        float d = length(g - f + o);

        float h = smoothstep(-1.0, 1.0, (dout - d) / w);
        dout = lerp(dout, d, h) - h * (1.0 - h) * w / (1.0 + 3.0 * w);
    }

    return dout;
}

float fbm1(float2 p, int octaves)
{
    float2x2 m = 2.0 * float2x2(4.0 / 5.0, 3.0 / 5.0, -3.0 / 5.0, 4.0 / 5.0);

    float scale = 0.5;
    float f = scale * noise1(p);
    float norm = scale;
    for (int i = 0; i < octaves; i++) {
        p = mul(m, p);
        scale *= 0.5;
        norm += scale;
        f += scale * noise1(p);
    }
    return 0.5 + 0.5 * f / norm;
}

float voronoise(float2 p)
{
    return voronoi(p, voronoi_smooth);
}

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = input.pos.xy;
    float2 uv = (2.0 * fragCoord - resolution.xy) / resolution.y;

    float2 toff = 0.1 * time * float2(4.0, 2.0);

    float2 p = (0.6 + 0.5 * sin(0.07 * time)) * float2(4.0, 4.0) * uv;

    float2 r = float2(fbm1(p + float2(5.0, 2.0), 4), fbm1(p + float2(1.0, 4.0), 4));

    float3 col = 1.2 * float3(1.4, 1.0, 0.5) *
        pow(float3(
            voronoise(p + 1.5 * r + toff),
            voronoise(p + 1.5 * r + toff + 0.005 * float2(2.0, 4.0)),
            voronoise(p + 1.5 * r + toff + 0.01 * float2(5.0, 1.0))),
            float3(1.5, 2.5, 2.9));

    col = s_curve(col);

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
