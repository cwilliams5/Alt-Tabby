// Vignette Breathe — Edge darkening with breathing opacity modulation

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;

    // Distance from center (0 at center, ~0.7 at corners)
    float2 d = uv - 0.5;
    float dist = length(d);

    // Vignette falloff
    float vignette = smoothstep(0.25, 0.75, dist);

    // Breathing modulation
    float breath = 0.85 + 0.15 * sin(time * 0.8);
    vignette *= breath;

    float3 col = float3(0.0, 0.0, 0.0);

    return AT_PostProcess(col, vignette);
}
