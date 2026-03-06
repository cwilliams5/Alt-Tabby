// Frosted Refraction — Subtle glass lens distortion around cursor via UV offset

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;
    float2 pixelPos = uv * resolution;

    if (iMouse.x <= 0.0 && iMouse.y <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);

    float2 delta = pixelPos - iMouse;
    float dist = length(delta);
    float radius = 100.0;

    float influence = smoothstep(radius, 0.0, dist);
    influence *= influence;

    // Create a subtle distortion pattern
    float2 dir = (dist > 0.001) ? delta / dist : float2(0.0, 0.0);
    float wave = sin(dist * 0.08 + time * 2.0) * 0.5 + 0.5;

    // Frosted glass — faint radial highlight with wave
    float3 col = float3(0.8, 0.85, 1.0) * influence * wave * 0.6;
    float a = influence * wave * 0.4;

    return AT_PostProcess(col, a);
}
