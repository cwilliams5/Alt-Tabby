// Ember — Warm amber: deep shadow, warm glow with firelight flicker on border

float roundedRectSDF(float2 p, float2 center, float2 halfSize, float radius) {
    float2 d = abs(p - center) - halfSize + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 pixelPos = input.uv * resolution;

    float2 rectCenter = selRect.xy + selRect.zw * 0.5;
    float2 halfSize = selRect.zw * 0.5;
    float radius = min(halfSize.x, halfSize.y) * 0.15;

    float dist = roundedRectSDF(pixelPos, rectCenter, halfSize, radius);

    // Deep shadow
    float2 shadowCenter = rectCenter + float2(0.0, 3.0);
    float shadowDist = roundedRectSDF(pixelPos, shadowCenter, halfSize + 5.0, radius + 2.0);
    float shadow = smoothstep(0.0, 15.0, -shadowDist) * 0.3;

    // Fill with warm tint
    float fill = smoothstep(1.0, -1.0, dist);
    float3 warmFill = selColor.rgb * float3(1.1, 0.9, 0.7);

    // Firelight flicker on border
    float flicker = 0.85 + 0.15 * sin(time * 4.0 + pixelPos.x * 0.03);
    float flicker2 = 0.9 + 0.1 * sin(time * 6.5 + pixelPos.y * 0.05);
    float combinedFlicker = flicker * flicker2;

    // Border with flicker
    float borderMask = smoothstep(borderWidth + 1.5, borderWidth - 0.5, abs(dist));
    float3 emberBorder = borderColor.rgb * float3(1.2, 0.85, 0.5) * combinedFlicker;

    // Warm outer glow
    float outerGlow = smoothstep(8.0, 0.0, dist) * (1.0 - fill) * 0.15;

    // Entrance + hover
    float t = smoothstep(0.0, 1.0, entranceT);
    float intensity = lerp(1.0, 0.5, isHovered);

    float3 col = float3(0.0, 0.0, 0.0);
    float a = shadow * t * intensity;

    float fillA = fill * selColor.a * t * intensity;
    col = lerp(col, warmFill, fillA);
    a = max(a, fillA);

    // Outer glow
    float3 glowCol = float3(1.0, 0.6, 0.2);
    col += glowCol * outerGlow * t * intensity;
    a = max(a, outerGlow * t * intensity);

    // Border
    float borderA = borderMask * borderColor.a * combinedFlicker * t * intensity;
    col = lerp(col, emberBorder, borderA);
    a = max(a, borderA);

    return float4(col * a, a) * opacity;
}
