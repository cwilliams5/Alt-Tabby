// 5 Nanoseconds After BigBang — converted from Shadertoy (wdtczM)
// Created by Benoit Marini - 2020
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.

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

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 R = resolution.xy;

    float4 o = (float4)0.0;
    float t = time * 0.1;
    for (float i = 0.0; i > -1.0; i -= 0.06)
    {
        float d = frac(i - 3.0 * t);
        float4 c = float4((fragCoord - R * 0.5) / R.y * d, i, 0.0) * 28.0;
        for (int j = 0; j < 27; j++)
            c.xzyw = abs(c / dot(c, c)
                    - float4(7.0 - 0.2 * sin(t), 6.3, 0.7, 1.0 - cos(t / 0.8)) / 7.0);
        o += c * c.yzww * (d - d * d) / float4(3, 5, 1, 1);
    }

    float3 color = o.rgb;

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
