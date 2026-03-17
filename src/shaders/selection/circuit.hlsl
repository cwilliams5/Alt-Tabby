// Circuit Selection — Pulse of light orbiting the border like a live circuit trace

float3 hue2rgb(float h) {
    float r = abs(h * 6.0 - 3.0) - 1.0;
    float g = 2.0 - abs(h * 6.0 - 2.0);
    float b = 2.0 - abs(h * 6.0 - 4.0);
    return saturate(float3(r, g, b));
}

// Map pixel to perimeter parameter (0-1 around the rect)
float getPerimeter(float2 px, float4 rect) {
    float2 center = rect.xy + rect.zw * 0.5;
    float2 delta = px - center;
    float angle = atan2(delta.y, delta.x); // -pi to pi
    return frac(angle * 0.15915494 + 0.5); // 0-1
}

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

    // Perimeter position (0-1 around the border)
    float perim = getPerimeter(px, selRect);

    // Two pulses orbiting at different speeds
    float pulseA = frac(time * 0.25);
    float pulseB = frac(time * 0.25 + 0.5); // opposite side

    // Wrapped distance from each pulse
    float dA = min(abs(perim - pulseA), min(abs(perim - pulseA + 1.0), abs(perim - pulseA - 1.0)));
    float dB = min(abs(perim - pulseB), min(abs(perim - pulseB + 1.0), abs(perim - pulseB - 1.0)));

    // Pulse glow — bright leading point with fading trail
    float glowA = smoothstep(0.20, 0.0, dA);
    float trailA = smoothstep(0.35, 0.0, dA) * 0.4;
    float glowB = smoothstep(0.20, 0.0, dB);
    float trailB = smoothstep(0.35, 0.0, dB) * 0.4;

    float pulse = max(glowA + trailA, glowB + trailB);

    // Pulse only on/near the border (not deep inside)
    float borderZone = smoothstep(8.0 * selGlow, 0.0, abs(dist));
    pulse *= borderZone;

    // Color: pulses have different hues that shift over time
    float hueA = frac(time * 0.05);
    float hueB = frac(time * 0.05 + 0.5);
    float3 colA = hue2rgb(hueA);
    float3 colB = hue2rgb(hueB);
    float3 pulseCol = lerp(colA, colB, step(dA, dB));

    // Inner circuit lines — subtle grid pattern
    float2 luv = (px - selRect.xy) / selRect.zw;
    float gridX = smoothstep(0.01, 0.0, abs(frac(luv.x * 8.0) - 0.5) - 0.48);
    float gridY = smoothstep(0.01, 0.0, abs(frac(luv.y * 3.0) - 0.5) - 0.48);
    float grid = max(gridX, gridY) * fill * 0.15;

    // Data pulse through grid lines
    float dataPulse = sin(luv.x * 25.0 - time * 4.0) * 0.5 + 0.5;
    grid *= 0.5 + 0.5 * dataPulse;

    float3 col = float3(0, 0, 0);
    float a = 0.0;

    // Fill with user color
    float fillA = fill * selColor.a * t * intensity;
    col = selColor.rgb;
    a = fillA;

    // Circuit grid overlay
    col += pulseCol * grid * 0.6 * t * intensity * selIntensity;
    a = max(a, grid * 0.3 * t * intensity * selIntensity);

    // Orbiting pulse glow
    col += pulseCol * pulse * 0.8 * t * intensity * selIntensity;
    a = max(a, pulse * 0.7 * t * intensity * selIntensity);

    // Border — lit up by passing pulse
    float borderLit = max(glowA, glowB) * selIntensity;
    float3 borderMix = lerp(borderColor.rgb, pulseCol * 0.6, borderLit);
    float borderA = borderMask * borderColor.a * t * intensity;
    float boostedBorderA = borderA * (1.0 + borderLit * 2.0);
    col = lerp(col, borderMix, saturate(boostedBorderA));
    a = max(a, boostedBorderA);

    return AT_PostProcess(col, saturate(a));
}
