// Gradient Drift — 2 warm/cool blobs orbiting center with Gaussian-like falloff
// Slow ~45s cycle with smooth color transitions

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;
    float aspect = resolution.x / resolution.y;

    float t = time * 0.14; // ~45s full cycle

    // Two blobs orbiting center
    float2 center = float2(0.5, 0.5);
    float2 p1 = center + float2(
        0.28 * cos(t),
        0.22 * sin(t * 1.1)
    );
    float2 p2 = center + float2(
        0.25 * cos(t * 0.85 + 3.14159),
        0.30 * sin(t * 0.95 + 3.14159)
    );

    // Gaussian-like falloff
    float2 auv = float2(uv.x * aspect, uv.y);
    float2 ap1 = float2(p1.x * aspect, p1.y);
    float2 ap2 = float2(p2.x * aspect, p2.y);

    float g1 = exp(-3.0 * dot(auv - ap1, auv - ap1));
    float g2 = exp(-3.0 * dot(auv - ap2, auv - ap2));

    // Warm (orange) and cool (blue) colors
    float3 warm = float3(0.90, 0.50, 0.15);
    float3 cool = float3(0.15, 0.45, 0.85);

    float3 col = warm * g1 + cool * g2;

    return AT_PostProcess(col);
}
