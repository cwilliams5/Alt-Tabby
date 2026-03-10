// Glass — Polished glass panel: soft drop shadow, subtle gradient fill, clean border, ambient glow breathe

float4 PSMain(PSInput input) : SV_Target {
    float2 pixelPos = input.uv * resolution;

    // Selection rect from cbuffer
    float2 rectCenter = selRect.xy + selRect.zw * 0.5;
    float2 halfSize = selRect.zw * 0.5;
    float radius = rowRadius > 0.0 ? rowRadius : min(halfSize.x, halfSize.y) * 0.15;

    float dist = roundedRectSDF(pixelPos, rectCenter, halfSize, radius);

    // Drop shadow (soft, offset down slightly)
    float2 shadowCenter = rectCenter + float2(0.0, 2.0);
    float shadowDist = roundedRectSDF(pixelPos, shadowCenter, halfSize + 4.0, radius + 2.0);
    float shadow = smoothstep(0.0, 12.0, -shadowDist) * 0.25;

    // Fill: subtle vertical gradient on top of user color
    float fill = smoothstep(1.0, -1.0, dist);
    float gradientT = saturate((pixelPos.y - selRect.y) / max(selRect.w, 1.0));
    float3 fillCol = selColor.rgb + float3(0.05, 0.05, 0.08) * (1.0 - gradientT);

    // Border
    float borderMask = smoothstep(borderWidth + 1.0, borderWidth, abs(dist));
    float3 borderCol3 = borderColor.rgb;

    // Ambient glow breathe
    float breathe = 0.9 + 0.1 * sin(time * 1.5);

    // Entrance animation
    float t = smoothstep(0.0, 1.0, entranceT);

    // Hover muting
    float intensity = isHovered;

    // Compose
    float3 col = float3(0.0, 0.0, 0.0);
    float a = 0.0;

    // Shadow layer
    col += float3(0.0, 0.0, 0.0);
    a += shadow * t * intensity;

    // Fill layer
    float fillA = fill * selColor.a * breathe * t * intensity;
    col = lerp(col, fillCol, fillA);
    a = max(a, fillA);

    // Gradient tint scaled by intensity
    col += float3(0.05, 0.05, 0.08) * (1.0 - gradientT) * fill * selIntensity * 0.5;

    // Border layer
    float borderA = borderMask * borderColor.a * t * intensity;
    col = lerp(col, borderCol3, borderA);
    a = max(a, borderA);

    return AT_PostProcess(col, a);
}
