// Spotlight — Gentle brightness cone at cursor, rest slightly dimmed

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;
    float2 pixelPos = uv * resolution;

    if (iMouse.x <= 0.0 && iMouse.y <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);

    float dist = length(pixelPos - iMouse);
    float radius = 180.0;

    // Spotlight cone
    float light = smoothstep(radius, radius * 0.3, dist);

    // Dim the rest slightly
    float dim = 0.08 * (1.0 - light);

    // Warm spotlight color
    float3 col = float3(1.0, 0.95, 0.85) * light * 0.25;

    // Combine: add brightness at cursor, add slight darkness elsewhere
    float3 darkCol = float3(0.0, 0.0, 0.0);
    float a = max(light * 0.2, dim);
    float3 finalCol = lerp(darkCol, col / max(a, 0.001), light * 0.2 / max(a, 0.001));

    return AT_PostProcess(col, light * 0.2);
}
