// The MIT License
// Copyright (c) 2013 Inigo Quilez
// substantial refactoring by 2021 Alalalat
// Converted from Shadertoy GLSL to Alt-Tabby HLSL

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

float2 hash(float2 p)
{
    p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
    return -1.0 + 2.0 * frac(sin(p) * 43758.5453123);
}

float noise(float2 p)
{
    const float K1 = 0.366025404; // (sqrt(3)-1)/2
    const float K2 = 0.211324865; // (3-sqrt(3))/6

    float2 i = floor(p + (p.x + p.y) * K1);
    float2 a = p - i + (i.x + i.y) * K2;
    float m = step(a.y, a.x);
    float2 o = float2(m, 1.0 - m);
    float2 b = a - o + K2;
    float2 c = a - 1.0 + 2.0 * K2;
    float3 h = max(0.5 - float3(dot(a, a), dot(b, b), dot(c, c)), 0.0);
    float3 n = h * h * h * h * float3(dot(a, hash(i + 0.0)), dot(b, hash(i + o)), dot(c, hash(i + 1.0)));
    return dot(n, float3(70.0, 70.0, 70.0));
}

float maximum3(float3 p)
{
    float mx = p.x;
    if (p.y > mx) mx = p.y;
    if (p.z > mx) mx = p.z;
    return mx;
}

float minimum3(float3 p)
{
    float mn = p.x;
    if (p.y < mn) mn = p.y;
    if (p.z < mn) mn = p.z;
    return mn;
}

float3 normalize2(float3 grosscolor)
{
    grosscolor = grosscolor * grosscolor * grosscolor;
    float mx = maximum3(grosscolor);
    float mn = minimum3(grosscolor);
    return grosscolor.xyz / (mx + mn);
}

float2 rotate(float2 oldpoint, float angle)
{
    float left, right;

    left = cos(angle) * oldpoint.x;
    left -= sin(angle) * oldpoint.y;
    right = sin(angle) * oldpoint.x;
    right += cos(angle) * oldpoint.y;

    return float2(left, right);
}

float noise4(float2 uv)
{
    float f = 0.5;
    float frequency = 1.75;
    float amplitude = 0.5;
    for (int i = 0; i < 7; i++) {
        f += amplitude * noise(frequency * uv - rotate(float2(log(time + 3.0), log(time + 3.0) / 999.0), time / 9999.0));
        frequency *= 2.0;
        amplitude *= 0.5;
    }
    return f;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 p = fragCoord.xy / resolution.xy;

    float2 uv = p * float2(resolution.x / resolution.y, 0.8);
    uv = rotate(uv, log(time) / -7.0);

    float interval = 10.0;
    float3 dblue = interval * float3(1.8, 2.6, 2.6);
    float3 cyan = interval * float3(0.0, 2.1, 2.0);
    float3 magenta = interval * float3(1.8, 1.0, 1.8);

    float f = 0.0;

    float3 color = float3(0.75, 0.75, 0.75);
    f = noise4(uv + noise4(uv) * (log(time + 1.0) + (time / 60.0)));
    color += f * normalize2(dblue);

    f = noise4(f * rotate(uv, sin(time / 11.0)) + f * noise4(f * uv));
    color += f * normalize2(cyan);

    f = noise4(f * rotate(uv, time / 7.0) + f * noise4(uv) * noise4(uv));
    color += f * normalize2(magenta);

    color = normalize2(color);

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
