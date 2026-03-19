// Caustics — Underwater light patterns that shimmer around cursor (pixel-only)
// Dappled light like sunlight through a swimming pool, intensifying near cursor.
// Moving the cursor shifts the "light source" creating crawling patterns.

float causticPattern(float2 uv, float t) {
    float c = 0.0;
    for (int i = 0; i < 4; i++) {
        float scale = 1.0 + (float)i * 0.7;
        float speed = 0.4 - (float)i * 0.05;
        float2 p = uv * scale;
        p.x += sin(p.y * 1.3 + t * speed) * 0.3;
        p.y += cos(p.x * 1.1 + t * speed * 0.8) * 0.3;
        c += abs(sin(p.x + sin(p.y + t * speed * 0.6))
               * sin(p.y + sin(p.x + t * speed * 0.7)));
    }
    return c * 0.25;
}

float causticPattern2(float2 uv, float t) {
    // Second layer with different frequency
    float c = 0.0;
    for (int i = 0; i < 3; i++) {
        float scale = 0.8 + (float)i * 0.9;
        float2 p = uv * scale + float2(t * 0.15, t * -0.12);
        c += abs(sin(p.x * 1.5 + cos(p.y * 1.2 + t * 0.3))
               * cos(p.y * 1.3 + sin(p.x * 1.4 - t * 0.25)));
    }
    return c * 0.33;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;
    float2 pixelPos = uv * resolution;

    if (iMouse.x <= 0.0 && iMouse.y <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);

    float2 delta = pixelPos - iMouse;
    float distSq = dot(delta, delta);

    // Influence radius — grows when moving
    float radius = 200.0 + smoothstep(0.0, 500.0, iMouseSpeed * reactivity) * 120.0;
    float earlyExitR = radius * 1.3;
    if (distSq > earlyExitR * earlyExitR) return float4(0.0, 0.0, 0.0, 0.0);

    float dist = sqrt(distSq);

    // Radial mask
    float mask = smoothstep(radius, radius * 0.15, dist);
    mask = mask * mask;  // stronger center

    // Caustic UV: world-space, shifted by cursor position for parallax
    float2 caustUV = pixelPos * 0.012 + iMouse * 0.002;

    // Two caustic layers for complexity
    float c1 = causticPattern(caustUV, time);
    float c2 = causticPattern2(caustUV * 1.3 + 5.0, time * 1.1);

    // Combine layers
    float caustic = c1 * 0.6 + c2 * 0.4;

    // Sharpen the pattern — caustics have bright peaks and dark valleys
    caustic = caustic * sqrt(caustic);

    // Apply cursor mask
    caustic *= mask;

    if (caustic < 0.001) return float4(0.0, 0.0, 0.0, 0.0);

    // Color: dappled light — warm white-gold with blue-cyan tint in shadows
    float3 brightCol = float3(1.0, 0.95, 0.8);   // warm light peak
    float3 ambientCol = float3(0.3, 0.5, 0.7);    // blue-cyan ambient

    float3 col = lerp(ambientCol * 0.2, brightCol, caustic);

    // Subtle chromatic shift at edges
    float edgeFactor = smoothstep(radius * 0.5, radius, dist);
    col.r *= 1.0 + edgeFactor * 0.1;
    col.b *= 1.0 - edgeFactor * 0.1;

    float alpha = caustic * 0.5 * mask;

    return AT_PostProcess(col, alpha);
}
