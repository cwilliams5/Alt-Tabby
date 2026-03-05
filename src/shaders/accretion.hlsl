/*
    Accretion by @XorDev
    Ported from Shadertoy: https://www.shadertoy.com/view/WcKXDV

    Refraction effect from adding raymarch iterator to turbulence.
*/

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float4 O = (float4)0;
    float z = 0.0;
    float d = 0.0;

    // Raymarch 20 steps
    for (float i = 0.0; i < 20.0; i += 1.0)
    {
        // Sample point (from ray direction)
        float3 p = z * normalize(float3(fragCoord + fragCoord, 0.0) - float3(resolution.x, resolution.y, resolution.x)) + 0.1;

        // Polar coordinates and additional transformations
        p = float3(atan2(p.y / 0.2, p.x) * 2.0, p.z / 3.0, length(p.xy) - 5.0 - z * 0.2);

        // Apply turbulence and refraction effect
        for (d = 0.0; d < 7.0; d += 1.0)
            p += sin(p.yzx * (d + 1.0) + time + 0.3 * (i + 1.0)) / (d + 1.0);

        // Distance to cylinder and waves with refraction
        d = length(float4(0.4 * cos(p) - 0.4, p.z));
        z += d;

        // Coloring and brightness
        O += (1.0 + cos(p.x + (i + 1.0) * 0.4 + z + float4(6.0, 1.0, 2.0, 0.0))) / d;
    }

    // Tanh tonemap
    O = tanh(O * O / 400.0);

    float3 color = O.rgb;

    return AT_PostProcess(color);
}