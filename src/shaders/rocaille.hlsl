// Rocaille - Converted from Shadertoy (WXyczK)
// Original by Xor (@XorDev)
// Multi-layer turbulence with time and color offsets
// https://www.shadertoy.com/view/WXyczK

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = input.pos.xy;

    // Centered and scaled coordinates
    float2 p = (fragCoord * 2.0 - resolution) / resolution.y / 0.3;

    // Turbulence layers
    float4 O = (float4)0;
    float2 v;
    for (float i = 1.0; i <= 9.0; i += 1.0) {
        // Turbulence accumulation
        v = p;
        for (float f = 1.0; f <= 9.0; f += 1.0)
            v += sin(v.yx * f + i + time) / f;
        // Color layer attenuated by turbulent distance
        O += (cos(i + float4(0, 1, 2, 3)) + 1.0) / 6.0 / length(v);
    }

    // Tanh tonemapping
    O = tanh(O * O);
    float3 color = O.rgb;

    return AT_PostProcess(color);
}
