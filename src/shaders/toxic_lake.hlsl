// Toxic Lake - Converted from Shadertoy (Xls3WM)
// Created by Reinder Nijhoff 2015
// Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// Based on https://www.shadertoy.com/view/4ls3D4 by Dave_Hoskins

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

#define n b = .5*(b + iChannel0.Sample(samp0, (c.xy + float2(37, 17) * floor(c.z)) / 256.).x); c *= .4;

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float3 p = float3(fragCoord.xy / resolution.xy - .5, .2);
    float3 d = p, a = p, b = (float3)0, c;

    [loop]
    for(int i = 0; i < 99; i++) {
        c = p; c.z += time * 5.;
        n
        n
        n
        a += (1. - a) * b.x * abs(p.y) / 4e2;
        p += d;
    }
    float3 color = 1. - a*a;

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float alpha = max(color.r, max(color.g, color.b));
    return float4(color * alpha, alpha);
}
