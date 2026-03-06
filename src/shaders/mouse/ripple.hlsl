// Ripple — Concentric wave rings emanating from cursor

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;
    float2 pixelPos = uv * resolution;

    if (iMouse.x <= 0.0 && iMouse.y <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);

    float dist = length(pixelPos - iMouse);
    float radius = 200.0;

    // Concentric rings moving outward
    float wave = sin(dist * 0.06 - time * 3.0);
    wave = wave * 0.5 + 0.5; // 0-1 range

    // Fade with distance
    float fade = smoothstep(radius, 0.0, dist);

    float intensity = wave * fade * fade;

    float3 col = float3(0.6, 0.7, 1.0) * intensity;

    return AT_PostProcess(col, intensity * 0.5);
}
