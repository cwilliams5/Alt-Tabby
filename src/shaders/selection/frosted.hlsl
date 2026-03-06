// Frosted — Diffuse frosted glass: extra-soft shadow, layered semi-transparent fills, top highlight band

float roundedRectSDF(float2 p, float2 center, float2 halfSize, float radius) {
    float2 d = abs(p - center) - halfSize + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 pixelPos = input.uv * resolution;

    float2 rectCenter = selRect.xy + selRect.zw * 0.5;
    float2 halfSize = selRect.zw * 0.5;
    float radius = min(halfSize.x, halfSize.y) * 0.18;

    float dist = roundedRectSDF(pixelPos, rectCenter, halfSize, radius);

    // Extra-soft shadow
    float2 shadowCenter = rectCenter + float2(0.0, 3.0);
    float shadowDist = roundedRectSDF(pixelPos, shadowCenter, halfSize + 6.0, radius + 3.0);
    float shadow = smoothstep(0.0, 18.0, -shadowDist) * 0.2;

    // Fill
    float fill = smoothstep(1.0, -1.0, dist);

    // Top highlight band
    float highlightY = saturate(1.0 - (pixelPos.y - selRect.y) / max(selRect.w * 0.15, 1.0));
    float highlight = highlightY * fill * 0.15;

    // Entrance + hover
    float t = smoothstep(0.0, 1.0, entranceT);
    float intensity = lerp(1.0, 0.45, isHovered);

    float3 col = float3(0.0, 0.0, 0.0);
    float a = shadow * t * intensity;

    float fillA = fill * selColor.a * t * intensity * 0.85;
    col = lerp(col, selColor.rgb, fillA);
    a = max(a, fillA);

    // Highlight
    float3 hiCol = selColor.rgb + float3(0.15, 0.15, 0.15);
    col = lerp(col, hiCol, highlight * t * intensity);
    a = max(a, highlight * t * intensity);

    // Border
    float borderMask = smoothstep(borderWidth + 1.0, borderWidth, abs(dist));
    float borderA = borderMask * borderColor.a * t * intensity;
    col = lerp(col, borderColor.rgb, borderA);
    a = max(a, borderA);

    return float4(col * a, a) * opacity;
}
