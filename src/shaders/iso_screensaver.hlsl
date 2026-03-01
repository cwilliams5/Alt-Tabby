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

float3 pal(float t, float3 a, float3 b, float3 c, float3 d)
{
    return a + b * cos(6.28318 * (c * t + d));
}

float hash(float2 p) {
    p += 0.4;
    float3 p3 = frac(float3(p.x, p.y, p.x) * 0.13);
    p3 += dot(p3, p3.yzx + 3.333);
    return frac((p3.x + p3.y) * p3.z);
}

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

float fbm(float2 x) {
    float v = 0.0;
    float a = 0.5;
    float2 shift = (float2)100;

    // GLSL mat2 is column-major; HLSL float2x2 is row-major — transposed
    float2x2 rot = float2x2(cos(0.5), -sin(0.5), sin(0.5), cos(0.5));
    for (int i = 0; i < 7; ++i) {
        v += a * noise(x);
        x = mul(rot, x) * 2.0 + shift;
        a *= 0.5;
    }
    return v;
}

float3 getColor(float2 p) {
    float f = fbm(p) - 0.1 * time;
    float n = floor(f * 10.0) / 10.0;

    float t = 2.0 * abs(frac(f * 10.0) - 0.5);

    float3 a = float3(0.5, 0.5, 0.5);
    float3 b = float3(0.5, 0.5, 0.5);
    float3 c = float3(1.0, 1.0, 1.0);
    float3 d = float3(0.3, 0.5, 0.7);

    float3 c1 = pal(9.19232 * n, a, b, c, d);
    float3 c2 = pal(9.19232 * (n - 1.0 / 10.0), a, b, c, d);

    return lerp(c1, c2, pow(t, 15.0));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 p = 5.0 * (fragCoord - 0.5 * resolution) / resolution.y;

    float3 col = getColor(p) - 0.3 * getColor(p + 0.02) - 0.3 * getColor(p + 0.01);
    col *= 2.0;

    col = pow(max(col, (float3)0), (float3)(1.0 / 2.2));

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float al = max(col.r, max(col.g, col.b));
    return float4(col * al, al);
}
