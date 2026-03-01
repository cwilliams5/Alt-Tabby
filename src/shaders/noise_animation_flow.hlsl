// Noise animation - Flow
// 2014 by nimitz (twitter: @stormoid)
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License
// Converted from Shadertoy (MdlXRS) to Alt-Tabby HLSL

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

#define t time*0.1
#define tau 6.2831853

static const float2x2 m2 = float2x2(0.80, 0.60, -0.60, 0.80);

float2x2 makem2(in float theta) {
    float c = cos(theta);
    float s = sin(theta);
    return float2x2(c, -s, s, c);
}

float noise(in float2 x) {
    return iChannel0.Sample(samp0, x * 0.01).x;
}

float grid(float2 p) {
    float s = sin(p.x) * cos(p.y);
    return s;
}

float flow(in float2 p) {
    float z = 2.0;
    float rz = 0.0;
    float2 bp = p;
    for (float i = 1.0; i < 7.0; i++) {
        bp += t * 1.5;
        float2 gr = float2(grid(p * 3.0 - t * 2.0), grid(p * 3.0 + 4.0 - t * 2.0)) * 0.4;
        gr = normalize(gr) * 0.4;
        gr = mul(gr, makem2((p.x + p.y) * 0.3 + t * 10.0));
        p += gr * 0.5;

        rz += (sin(noise(p) * 8.0) * 0.5 + 0.5) / z;

        p = lerp(bp, p, 0.5);
        z *= 1.7;
        p *= 2.5;
        p = mul(p, m2);
        bp *= 2.5;
        bp = mul(bp, m2);
    }
    return rz;
}

float spiral(float2 p, float scl) {
    float r = length(p);
    r = log(r);
    float a = atan2(p.y, p.x);
    return abs(fmod(scl * (r - 2.0 / scl * a), tau) - 1.0) * 2.0;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 p = fragCoord.xy / resolution.xy - 0.5;
    p.x *= resolution.x / resolution.y;
    p *= 3.0;
    float rz = flow(p);
    p /= exp(fmod(t * 3.0, 2.1));
    rz *= (6.0 - spiral(p, 3.0)) * 0.9;
    float3 col = float3(0.2, 0.07, 0.01) / rz;
    col = pow(abs(col), (float3)1.01);

    // darken/desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}