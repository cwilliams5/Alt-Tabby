// Gradient Orbit Selection — Moving gradient that smoothly rotates around the border

float3 hue2rgb(float h) {
    float r = abs(h * 6.0 - 3.0) - 1.0;
    float g = 2.0 - abs(h * 6.0 - 2.0);
    float b = 2.0 - abs(h * 6.0 - 4.0);
    return saturate(float3(r, g, b));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 px = input.uv * resolution;
    float2 rc = selRect.xy + selRect.zw * 0.5;
    float2 hs = selRect.zw * 0.5;
    float rad = rowRadius > 0.0 ? rowRadius : min(hs.x, hs.y) * 0.15;
    float dist = roundedRectSDF(px, rc, hs, rad);
    float fill = smoothstep(1.0, -1.0, dist);
    float borderMask = smoothstep(borderWidth + 1.5, borderWidth - 0.5, abs(dist));

    float t = smoothstep(0.0, 1.0, entranceT);
    float intensity = isHovered;

    // Angle from center (0-1)
    float2 delta = px - rc;
    float angle = atan2(delta.y, delta.x);
    float perim = frac(angle / 6.28318 + 0.5);

    // Rotating gradient — full spectrum cycling around the border
    float rotation = time * 0.15;
    float gradAngle = frac(perim + rotation);

    // Gradient color — full rainbow
    float3 gradCol = hue2rgb(gradAngle);

    // Border intensity varies — brightest at the "leading edge" of rotation
    float leadEdge = frac(rotation);
    float dLead = min(abs(perim - leadEdge), min(abs(perim - leadEdge + 1.0), abs(perim - leadEdge - 1.0)));
    float leadBright = smoothstep(0.3, 0.0, dLead);

    // Border glow — wider near the lead point
    float borderZone = smoothstep(borderWidth + 2.0 + leadBright * 6.0, borderWidth - 0.5, abs(dist));

    // Inner fill gradient — subtle color wash
    float2 luv = (px - selRect.xy) / selRect.zw;
    float innerGrad = frac(luv.x * 0.5 + luv.y * 0.3 + rotation);
    float3 innerCol = hue2rgb(innerGrad) * 0.3;

    float3 col = float3(0, 0, 0);
    float a = 0.0;

    // Fill with user color
    float fillA = fill * selColor.a * t * intensity;
    col = selColor.rgb;
    a = fillA;

    // Inner gradient wash
    col += innerCol * fill * 0.3 * t * intensity * selIntensity;

    // Gradient border glow
    float glowA2 = borderZone * t * intensity * selIntensity;
    col += gradCol * glowA2 * 0.6;
    a = max(a, glowA2 * 0.7);

    // Outer glow — extends further near lead point
    float outerGlow = smoothstep((8.0 + leadBright * 8.0) * selGlow, 0.0, dist) * (1.0 - fill) * 0.25;
    col += gradCol * outerGlow * t * intensity * selIntensity;
    a = max(a, outerGlow * t * intensity * selIntensity);

    // Main border stroke
    float3 borderMix = lerp(borderColor.rgb, gradCol * 0.6, 0.6 * selIntensity);
    float borderA = borderMask * borderColor.a * t * intensity;
    col = lerp(col, borderMix, saturate(borderA));
    a = max(a, borderA);

    return AT_PostProcess(col, saturate(a));
}
