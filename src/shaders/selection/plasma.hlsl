// Plasma Selection — Vivid morphing plasma blobs with bold color

float4 PSMain(PSInput input) : SV_Target {
    float2 px = input.uv * resolution;
    float2 hs = selRect.zw * 0.5;
    float2 rc = selRect.xy + hs;
    float rad = rowRadius > 0.0 ? rowRadius : min(hs.x, hs.y) * 0.15;
    float dist = roundedRectSDF(px, rc, hs, rad);
    float fill = smoothstep(1.0, -1.0, dist);
    float borderMask = smoothstep(borderWidth + 1.5, borderWidth - 0.5, abs(dist));

    float t = smoothstep(0.0, 1.0, entranceT);
    float intensity = isHovered;
    float tI = t * intensity;
    float tIS = tI * selIntensity;

    // Local UV with aspect correction
    float2 luv = (px - selRect.xy) / selRect.zw;
    float aspect = selRect.z / max(selRect.w, 1.0);
    float2 uv = float2(luv.x * aspect, luv.y) * 4.0;

    // Classic plasma — overlapping sine waves
    float v = 0.0;
    v += sin(uv.x * 1.2 + time * 1.0);
    v += sin(uv.y * 1.1 + time * 0.8);
    v += sin((uv.x + uv.y) * 0.7 + time * 0.6);
    v += sin(length(uv - float2(aspect * 2.0, 2.0)) * 1.5 + time * 1.2);
    v *= 0.25; // normalize to ~[-1, 1]

    // Bold vivid colors from the plasma value (120-degree phase decomposition)
    float sv, cv;
    sincos(v * 3.14159, sv, cv);
    float3 plasmaCol;
    plasmaCol.r = sv * 0.5 + 0.5;
    plasmaCol.g = (sv * (-0.5) + cv * 0.86603) * 0.5 + 0.5;
    plasmaCol.b = (sv * (-0.5) + cv * (-0.86603)) * 0.5 + 0.5;

    // Boost saturation and brightness
    plasmaCol = pow(plasmaCol, float3(0.8, 0.8, 0.8)) * 1.2;

    float3 col = float3(0, 0, 0);
    float a = 0.0;

    // Fill — blend user color with plasma
    float fillA = fill * tI;
    float3 baseFill = lerp(selColor.rgb, plasmaCol * selColor.a, 0.55 * selIntensity);
    col = baseFill * fillA;
    a = max(selColor.a, 0.6) * fillA;

    // Outer plasma glow
    float outerGlow = smoothstep(10.0 * selGlow, 0.0, dist) * (1.0 - fill) * 0.25;
    col += plasmaCol * outerGlow * tIS * 0.5;
    a = max(a, outerGlow * tIS);

    // Border — tinted by plasma
    float3 borderMix = lerp(borderColor.rgb, plasmaCol * 0.4, 0.5 * selIntensity);
    float borderA = borderMask * borderColor.a * tI;
    col = lerp(col, borderMix, saturate(borderA));
    a = max(a, borderA);

    return AT_PostProcess(col, saturate(a));
}
