// Aurora Selection — Prismatic: color-shifting border glow cycling through hues, subtle rainbow reflections

float4 PSMain(PSInput input) : SV_Target {
    float2 pixelPos = input.uv * resolution;

    float2 halfSize = selRect.zw * 0.5;
    float2 rectCenter = selRect.xy + halfSize;
    float radius = rowRadius > 0.0 ? rowRadius : min(halfSize.x, halfSize.y) * 0.15;

    float dist = roundedRectSDF(pixelPos, rectCenter, halfSize, radius);

    float fill = smoothstep(1.0, -1.0, dist);

    // Color cycling based on position along border + time
    float perim = (pixelPos.x - selRect.x + pixelPos.y - selRect.y) / (selRect.z + selRect.w);
    float hue = frac(perim * 0.5 + time * 0.1);

    float3 prismatic = hue2rgb(hue);

    // Border glow with prismatic color
    float borderMask = smoothstep(borderWidth + 1.5, borderWidth - 0.5, abs(dist));

    // Outer rainbow glow
    float outerGlow = smoothstep(10.0 * selGlow, 0.0, dist) * (1.0 - fill) * 0.3;

    // Subtle inner rainbow reflections
    float innerRef = smoothstep(0.0, -8.0, dist) * fill * 0.1;

    float t = smoothstep(0.0, 1.0, entranceT);
    float intensity = isHovered;
    float tI = t * intensity;
    float tIS = tI * selIntensity;

    float3 col = float3(0.0, 0.0, 0.0);
    float a = 0.0;

    // Fill with user color
    float fillA = fill * selColor.a * tI;
    col = selColor.rgb;
    a = fillA;

    // Inner reflections
    col += prismatic * innerRef * tIS;

    // Outer glow
    col += prismatic * outerGlow * tIS;
    a = max(a, outerGlow * tIS);

    // Prismatic border
    float3 borderCol3 = lerp(borderColor.rgb, prismatic, 0.7 * selIntensity);
    float borderA = borderMask * borderColor.a * tI;
    col = lerp(col, borderCol3, borderA);
    a = max(a, borderA);

    return AT_PostProcess(col, saturate(a));
}
