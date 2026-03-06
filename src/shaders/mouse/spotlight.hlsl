// Spotlight — Gentle brightness cone at cursor, rest slightly dimmed
// Radius expands slightly when mouse moves fast.

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;
    float2 pixelPos = uv * resolution;

    if (iMouse.x <= 0.0 && iMouse.y <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);

    float dist = length(pixelPos - iMouse);

    // Radius expands with mouse speed
    float radius = 180.0 + smoothstep(0.0, 2000.0, iMouseSpeed) * 60.0;

    // Spotlight cone
    float light = smoothstep(radius, radius * 0.3, dist);

    // Dim the rest slightly
    float dim = 0.08 * (1.0 - light);

    // Warm spotlight color
    float3 col = float3(1.0, 0.95, 0.85) * light * 0.25;

    return AT_PostProcess(col, light * 0.2);
}
