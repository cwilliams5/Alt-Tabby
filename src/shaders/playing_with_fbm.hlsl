// 'Playing with FBM' by Lallis
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.
// Converted from https://www.shadertoy.com/view/XlXXz8

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

float noise3D(float3 p)
{
    return frac(sin(dot(p, float3(12.9898, 78.233, 126.7378))) * 43758.5453) * 2.0 - 1.0;
}

float linear3D(float3 p)
{
    float3 p0 = floor(p);
    float3 p1x = float3(p0.x + 1.0, p0.y, p0.z);
    float3 p1y = float3(p0.x, p0.y + 1.0, p0.z);
    float3 p1z = float3(p0.x, p0.y, p0.z + 1.0);
    float3 p1xy = float3(p0.x + 1.0, p0.y + 1.0, p0.z);
    float3 p1xz = float3(p0.x + 1.0, p0.y, p0.z + 1.0);
    float3 p1yz = float3(p0.x, p0.y + 1.0, p0.z + 1.0);
    float3 p1xyz = p0 + 1.0;

    float r0 = noise3D(p0);
    float r1x = noise3D(p1x);
    float r1y = noise3D(p1y);
    float r1z = noise3D(p1z);
    float r1xy = noise3D(p1xy);
    float r1xz = noise3D(p1xz);
    float r1yz = noise3D(p1yz);
    float r1xyz = noise3D(p1xyz);

    float a = lerp(r0, r1x, p.x - p0.x);
    float b = lerp(r1y, r1xy, p.x - p0.x);
    float ab = lerp(a, b, p.y - p0.y);
    float c = lerp(r1z, r1xz, p.x - p0.x);
    float d = lerp(r1yz, r1xyz, p.x - p0.x);
    float cd = lerp(c, d, p.y - p0.y);

    float res = lerp(ab, cd, p.z - p0.z);

    return res;
}

float fbm(float3 p)
{
    float f = 0.5000 * linear3D(p * 1.0);
    f += 0.2500 * linear3D(p * 2.01);
    f += 0.1250 * linear3D(p * 4.02);
    f += 0.0625 * linear3D(p * 8.03);
    f /= 0.9375;
    return f;
}

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord / resolution.xy * 2.0 - 1.0;
    uv.x *= resolution.x / resolution.y;
    float ang = time * 0.1;
    float2x2 rot = float2x2(cos(ang), -sin(ang), sin(ang), cos(ang));
    uv = mul(rot, uv) * 16.0 * (sin(time * 0.1) + 1.5);

    float f = fbm(float3(uv, time) + fbm(float3(uv, time) + fbm(float3(uv, time)))) * 0.5 + 0.5;

    float3 col, col2;
    col = (float3)fbm(float3(uv * f * 0.3, time * 0.75));
    col2 = col;

    col *= float3((sin(time * 0.2) * 0.5 + 1.5), 1.0, 0.6);
    col += float3(0.1, 0.7, 0.8) * f;

    col2 *= float3(0.9, 1.0, (sin(time * 0.2) * 0.5 + 1.5));
    col2 += float3(0.8, 0.5, 0.1) * f;

    col = lerp(col, col2, smoothstep(-50.0, 50.0, uv.x));

    col *= lerp(0.5, sin(time * 0.5) * 0.25 + 1.0, length(col));

    col = clamp(col, 0.0, 1.0);

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
