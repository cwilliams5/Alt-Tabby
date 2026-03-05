// 5 Nanoseconds After BigBang — converted from Shadertoy (wdtczM)
// Created by Benoit Marini - 2020
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 R = resolution.xy;

    float4 o = (float4)0.0;
    float t = time * 0.1;
    float4 sub = float4(7.0 - 0.2 * sin(t), 6.3, 0.7, 1.0 - cos(t * 1.25)) * (1.0 / 7.0);
    static const float4 invDiv = float4(0.33333333, 0.2, 1.0, 1.0);
    for (float i = 0.0; i > -1.0; i -= 0.06)
    {
        float d = frac(i - 3.0 * t);
        float4 c = float4((fragCoord - R * 0.5) / R.y * d, i, 0.0) * 28.0;
        for (int j = 0; j < 27; j++)
            c.xzyw = abs(c / dot(c, c) - sub);
        o += c * c.yzww * d * (1.0 - d) * invDiv;
    }

    float3 color = o.rgb;

    return AT_PostProcess(color);
}
