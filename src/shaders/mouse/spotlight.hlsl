// Spotlight — Gentle brightness cone at cursor, rest slightly dimmed
// Radius expands slightly when mouse moves fast.
// Visual polish: noise-distorted edge, subtle caustic pattern, chromatic fringe.

float hash21(float2 p) {
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float noise2D(float2 p) {
    float2 i = floor(p);
    float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);  // smoothstep interpolation
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;
    float2 pixelPos = uv * resolution;

    if (iMouse.x <= 0.0 && iMouse.y <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);

    float2 delta = pixelPos - iMouse;
    float dist = length(delta);

    // Radius expands with mouse speed
    float radius = 180.0 + smoothstep(0.0, 2000.0, iMouseSpeed) * 60.0;

    // Noise-distorted edge: break the perfect circle
    float angle = atan2(delta.y, delta.x);
    float edgeNoise = noise2D(float2(angle * 3.0, time * 0.5)) * 0.15;
    float noisyDist = dist * (1.0 + edgeNoise);

    // Spotlight cone with soft noisy edge
    float light = smoothstep(radius, radius * 0.3, noisyDist);

    // Subtle caustic pattern inside the cone
    float caustic = sin(dist * 0.08 + time * 1.2) * sin(dist * 0.12 - time * 0.8);
    caustic = caustic * 0.5 + 0.5;
    caustic = pow(caustic, 3.0) * 0.15 * light;

    // Chromatic fringe at edge (warm channel slightly larger)
    float lightR = smoothstep(radius * 1.03, radius * 0.3, noisyDist);
    float lightB = smoothstep(radius * 0.97, radius * 0.3, noisyDist);

    // Warm spotlight color with fringe
    float3 col = float3(
        (1.0 * lightR + caustic) * 0.25,
        (0.95 * light + caustic * 0.8) * 0.25,
        (0.85 * lightB + caustic * 0.6) * 0.25
    );

    float alpha = light * 0.2 + caustic * 0.3;
    return AT_PostProcess(col, alpha);
}
