// Pulse — Rhythmic: border expands/contracts with breathing cycle, soft radial expansion wave

float roundedRectSDF(float2 p, float2 center, float2 halfSize, float radius) {
    float2 d = abs(p - center) - halfSize + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 pixelPos = input.uv * resolution;

    float2 rectCenter = selRect.xy + selRect.zw * 0.5;
    float2 halfSize = selRect.zw * 0.5;
    float radius = min(halfSize.x, halfSize.y) * 0.15;

    // Breathing: border width oscillates
    float breathe = sin(time * 2.0) * 0.5 + 0.5;
    float dynBorderWidth = borderWidth * (0.8 + breathe * 0.4);

    float dist = roundedRectSDF(pixelPos, rectCenter, halfSize, radius);
    float fill = smoothstep(1.0, -1.0, dist);

    // Expansion wave: ring that pulses outward
    float waveDist = abs(dist) - frac(time * 0.5) * 20.0;
    float wave = smoothstep(3.0, 0.0, abs(waveDist)) * (1.0 - fill) * 0.15;
    wave *= smoothstep(25.0, 5.0, dist); // fade at distance

    // Border with breathing width
    float borderMask = smoothstep(dynBorderWidth + 1.0, dynBorderWidth, abs(dist));

    // Shadow
    float2 shadowCenter = rectCenter + float2(0.0, 2.0);
    float shadowDist = roundedRectSDF(pixelPos, shadowCenter, halfSize + 4.0, radius + 2.0);
    float shadow = smoothstep(0.0, 12.0, -shadowDist) * 0.2;

    float t = smoothstep(0.0, 1.0, entranceT);
    float intensity = lerp(1.0, 0.5, isHovered);

    float3 col = float3(0.0, 0.0, 0.0);
    float a = shadow * t * intensity;

    // Fill
    float fillA = fill * selColor.a * t * intensity;
    col = selColor.rgb;
    a = max(a, fillA);

    // Wave
    col += borderColor.rgb * wave * t * intensity;
    a = max(a, wave * t * intensity);

    // Border
    float borderA = borderMask * borderColor.a * t * intensity;
    col = lerp(col, borderColor.rgb, saturate(borderA));
    a = max(a, borderA);

    a = saturate(a);
    return float4(col * a, a) * opacity;
}
