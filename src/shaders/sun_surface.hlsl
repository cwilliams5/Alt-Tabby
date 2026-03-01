// Sun Surface — converted from Shadertoy XlSSzK by Duke
// Based on Shanes' Fiery Spikeball
// License: CC BY-NC-SA 3.0

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

#define DITHERING

static const float pi = 3.14159265;

// IQ's noise
float pn(float3 p)
{
    float3 ip = floor(p);
    p = frac(p);
    p *= p * (3.0 - 2.0 * p);
    float2 uv = (ip.xy + float2(37.0, 17.0) * ip.z) + p.xy;
    float2 s = iChannel0.SampleLevel(samp0, (uv + 0.5) / 256.0, 0.0).yx;
    return lerp(s.x, s.y, p.z);
}

// FBM
float fpn(float3 p) {
    return pn(p * 0.06125) * 0.57 + pn(p * 0.125) * 0.28 + pn(p * 0.25) * 0.15;
}

float rand2d(float2 co) {
    return frac(sin(dot(co * 0.123, float2(12.9898, 78.233))) * 43758.5453);
}

float cosNoise(float2 p)
{
    return 0.5 * (sin(p.x) + sin(p.y));
}

// mat2 m2 = mat2(1.6,-1.2, 1.2,1.6) applied as multiply
float2 mulM2(float2 v) {
    return float2(1.6 * v.x - 1.2 * v.y, 1.2 * v.x + 1.6 * v.y);
}

float sdTorus(float3 p, float2 t)
{
    return length(float2(length(p.xz) - t.x * 1.2, p.y)) - t.y;
}

float smin(float a, float b, float k)
{
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

float SunSurface(float3 pos)
{
    float h = 0.0;
    float2 q = pos.xz * 0.5;

    float s = 0.5;

    for (int i = 0; i < 6; i++)
    {
        h += s * cosNoise(q);
        q = mulM2(q) * 0.85;
        q += float2(2.41, 8.13);
        s *= 0.48 + 0.2 * h;
    }
    h *= 2.0;

    float d1 = pos.y - h;

    // rings — GLSL mod(a,b) = a - b*floor(a/b)
    float3 modArg = 2.3 + pos + 1.0;
    float3 r1 = modArg - 10.0 * floor(modArg / 10.0) - 5.0;
    r1.y = pos.y - 0.1 - 0.7 * h + 0.5 * sin(3.0 * time + pos.x + 3.0 * pos.z);
    float c = cos(pos.x);
    float s1 = 1.0;
    float2 rxz = float2(c * r1.x + s1 * r1.z, c * r1.z - s1 * r1.x);
    r1.x = rxz.x;
    r1.z = rxz.y;
    float d2 = sdTorus(r1.xzy, float2(clamp(abs(pos.x / pos.z), 0.7, 2.5), 0.20));

    return smin(d1, d2, 1.0);
}

float map(float3 p) {
    p.z += 1.0;
    // R(p.yz, -25.5)
    float a1 = -25.5;
    float c1 = cos(a1); float s1 = sin(a1);
    float2 pyz = c1 * p.yz + s1 * float2(p.z, -p.y);
    p.y = pyz.x; p.z = pyz.y;
    // R(p.xz, time*0.1) — iMouse zeroed, just time rotation
    float a2 = time * 0.1;
    float c2 = cos(a2); float s2 = sin(a2);
    float2 pxz = c2 * p.xz + s2 * float2(p.z, -p.x);
    p.x = pxz.x; p.z = pxz.y;
    return SunSurface(p) + fpn(p * 50.0 + time * 25.0) * 0.45;
}

// Fire palette from Combustible Voronoi
float3 firePalette(float i) {
    float T = 1400.0 + 1300.0 * i;
    float3 L = float3(7.4, 5.6, 4.4);
    L = pow(L, (float3)5.0) * (exp(1.43876719683e5 / (T * L)) - 1.0);
    return 1.0 - exp(-5e8 / L);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float3 rd = normalize(float3((fragCoord - 0.5 * resolution) / resolution.y, 1.0));
    float3 ro = float3(0.0, 0.0, -22.0);

    float ld = 0.0, td = 0.0, w = 0.0;
    float d = 1.0, t = 1.0;

    const float h = 0.1;
    float3 tc = (float3)0.0;

#ifdef DITHERING
    float2 pos2 = fragCoord / resolution;
    float2 seed = pos2 + frac(time);
#endif

    [loop]
    for (int i = 0; i < 56; i++) {
        if (td > (1.0 - 1.0 / 80.0) || d < 0.001 * t || t > 40.0) break;

        d = map(ro + t * rd);

        ld = (h - d) * step(d, h);
        w = (1.0 - td) * ld;

        tc += w * w + 1.0 / 50.0;
        td += w + 1.0 / 200.0;

#ifdef DITHERING
        d = abs(d) * (0.8 + 0.28 * rand2d(seed * float2((float)i, (float)i)));
        d = max(d, 0.04);
#else
        d = max(d, 0.04);
#endif

        t += d * 0.5;
    }

    tc = firePalette(tc.x);

    float3 color = tc;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
