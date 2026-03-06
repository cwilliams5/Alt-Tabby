// Neon — Bright cyberpunk: double glow (inner+outer), bright border, darkened fill, bloom entrance

float roundedRectSDF(float2 p, float2 center, float2 halfSize, float radius) {
    float2 d = abs(p - center) - halfSize + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 pixelPos = input.uv * resolution;

    float2 rectCenter = selRect.xy + selRect.zw * 0.5;
    float2 halfSize = selRect.zw * 0.5;
    float radius = min(halfSize.x, halfSize.y) * 0.12;

    float dist = roundedRectSDF(pixelPos, rectCenter, halfSize, radius);

    float fill = smoothstep(1.0, -1.0, dist);

    // Darkened fill
    float3 darkFill = selColor.rgb * 0.3;

    // Outer glow
    float outerGlow = smoothstep(14.0, 0.0, dist) * (1.0 - fill);

    // Inner glow
    float innerGlow = smoothstep(0.0, -6.0, dist) * fill;

    // Bright border
    float borderMask = smoothstep(borderWidth + 1.0, borderWidth, abs(dist));

    // Bloom entrance: glow starts wide and narrows
    float t = smoothstep(0.0, 1.0, entranceT);
    float bloomT = 1.0 + (1.0 - t) * 2.0; // starts 3x, narrows to 1x
    float bloom = smoothstep(14.0 * bloomT, 0.0, dist) * (1.0 - fill) * (1.0 - t) * 0.5;

    float intensity = lerp(1.0, 0.4, isHovered);

    float3 glowColor = borderColor.rgb * 1.5;

    float3 col = float3(0.0, 0.0, 0.0);
    float a = 0.0;

    // Fill
    float fillA = fill * selColor.a * 0.6 * t * intensity;
    col = darkFill;
    a = fillA;

    // Inner glow
    col += glowColor * innerGlow * 0.3 * t * intensity;
    a = max(a, innerGlow * 0.3 * t * intensity);

    // Outer glow
    col += glowColor * outerGlow * 0.4 * t * intensity;
    a = max(a, outerGlow * 0.35 * t * intensity);

    // Bloom
    col += glowColor * bloom;
    a = max(a, bloom * 0.5);

    // Border
    float borderA = borderMask * borderColor.a * 1.2 * t * intensity;
    col = lerp(col, borderColor.rgb * 1.3, saturate(borderA));
    a = max(a, borderA);

    a = saturate(a);
    return float4(col * a, a) * opacity;
}
