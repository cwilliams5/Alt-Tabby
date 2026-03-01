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

#define t (time / 2.0)

float noise3D(float3 p)
{
    return frac(sin(dot(p, float3(12.9898, 78.233, 128.852))) * 43758.5453) * 2.0 - 1.0;
}

float simplex3D(float3 p)
{
    float f3 = 1.0 / 3.0;
    float s = (p.x + p.y + p.z) * f3;
    int i = (int)floor(p.x + s);
    int j = (int)floor(p.y + s);
    int k = (int)floor(p.z + s);

    float g3 = 1.0 / 6.0;
    float tt = (float)(i + j + k) * g3;
    float x0 = (float)i - tt;
    float y0 = (float)j - tt;
    float z0 = (float)k - tt;
    x0 = p.x - x0;
    y0 = p.y - y0;
    z0 = p.z - z0;

    int i1, j1, k1;
    int i2, j2, k2;

    if (x0 >= y0)
    {
        if (y0 >= z0) { i1 = 1; j1 = 0; k1 = 0; i2 = 1; j2 = 1; k2 = 0; }
        else if (x0 >= z0) { i1 = 1; j1 = 0; k1 = 0; i2 = 1; j2 = 0; k2 = 1; }
        else { i1 = 0; j1 = 0; k1 = 1; i2 = 1; j2 = 0; k2 = 1; }
    }
    else
    {
        if (y0 < z0) { i1 = 0; j1 = 0; k1 = 1; i2 = 0; j2 = 1; k2 = 1; }
        else if (x0 < z0) { i1 = 0; j1 = 1; k1 = 0; i2 = 0; j2 = 1; k2 = 1; }
        else { i1 = 0; j1 = 1; k1 = 0; i2 = 1; j2 = 1; k2 = 0; }
    }

    float x1 = x0 - (float)i1 + g3;
    float y1 = y0 - (float)j1 + g3;
    float z1 = z0 - (float)k1 + g3;
    float x2 = x0 - (float)i2 + 2.0 * g3;
    float y2 = y0 - (float)j2 + 2.0 * g3;
    float z2 = z0 - (float)k2 + 2.0 * g3;
    float x3 = x0 - 1.0 + 3.0 * g3;
    float y3 = y0 - 1.0 + 3.0 * g3;
    float z3 = z0 - 1.0 + 3.0 * g3;

    float3 ijk0 = float3(i, j, k);
    float3 ijk1 = float3(i + i1, j + j1, k + k1);
    float3 ijk2 = float3(i + i2, j + j2, k + k2);
    float3 ijk3 = float3(i + 1, j + 1, k + 1);

    float3 gr0 = normalize(float3(noise3D(ijk0), noise3D(ijk0 * 2.01), noise3D(ijk0 * 2.02)));
    float3 gr1 = normalize(float3(noise3D(ijk1), noise3D(ijk1 * 2.01), noise3D(ijk1 * 2.02)));
    float3 gr2 = normalize(float3(noise3D(ijk2), noise3D(ijk2 * 2.01), noise3D(ijk2 * 2.02)));
    float3 gr3 = normalize(float3(noise3D(ijk3), noise3D(ijk3 * 2.01), noise3D(ijk3 * 2.02)));

    float n0 = 0.0;
    float n1 = 0.0;
    float n2 = 0.0;
    float n3 = 0.0;

    float t0 = 0.5 - x0 * x0 - y0 * y0 - z0 * z0;
    if (t0 >= 0.0)
    {
        t0 *= t0;
        n0 = t0 * t0 * dot(gr0, float3(x0, y0, z0));
    }
    float t1 = 0.5 - x1 * x1 - y1 * y1 - z1 * z1;
    if (t1 >= 0.0)
    {
        t1 *= t1;
        n1 = t1 * t1 * dot(gr1, float3(x1, y1, z1));
    }
    float t2 = 0.5 - x2 * x2 - y2 * y2 - z2 * z2;
    if (t2 >= 0.0)
    {
        t2 *= t2;
        n2 = t2 * t2 * dot(gr2, float3(x2, y2, z2));
    }
    float t3 = 0.5 - x3 * x3 - y3 * y3 - z3 * z3;
    if (t3 >= 0.0)
    {
        t3 *= t3;
        n3 = t3 * t3 * dot(gr3, float3(x3, y3, z3));
    }
    return 96.0 * (n0 + n1 + n2 + n3);
}

float fbm(float3 p)
{
    float f;
    f  = 0.50000 * simplex3D(p); p = p * 2.01;
    f += 0.25000 * simplex3D(p); p = p * 2.02;
    f += 0.12500 * simplex3D(p); p = p * 2.03;
    f += 0.06250 * simplex3D(p); p = p * 2.04;
    f += 0.03125 * simplex3D(p);
    return f * 0.5 + 0.5;
}

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord.xy / resolution.xy * 2.0 - 1.0;
    uv.x *= (resolution.x / resolution.y);
    float n = fbm(float3(t, uv * 5.0));

    float3 color = float3(n, n, n);

    // Darken / desaturate
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
