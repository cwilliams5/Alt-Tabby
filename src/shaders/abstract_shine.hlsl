// Converted from Shadertoy: Abstract Shine by Frostbyte_
// https://www.shadertoy.com/view/w3yyzc
// SPDX-License-Identifier: CC-BY-NC-SA-4.0

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

float2x2 rot(float a) {
    float4 c = cos(a + float4(0, 33, 11, 0));
    return float2x2(c.x, c.z, c.y, c.w);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float i = 0.0, s, t = time;
    float4 o = (float4)0;
    float3 p = float3(0, 0, t);
    float3 d = normalize(float3(2.0 * fragCoord - resolution, resolution.y));

    for (; i < 10.0; i += 1.0)
    {
        p.xy = mul(rot(-p.z * 0.01 - time * 0.05), p.xy);
        s = 0.0;
        s = max(s, 15.0 * (-length(p.xy) + 3.0));
        s += abs(p.y * 0.004 + sin(t - p.x * 0.5) * 0.9 + 1.0);
        p += d * s;
        o += (1.0 + sin(i * 0.9 + length(p.xy * 0.1) + float4(9, 1.5, 1, 1))) / s;
    }
    o /= 1e2;

    float3 color = o.rgb;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
