// Spotlight — Physically-motivated spotlight from above the window center (pixel-only)
// The spotlight source is fixed above the center of the window.
// As cursor moves away from center, the spot elongates (perspective foreshortening).
// Moving cursor makes the spot larger (like a shaky hand). Soft penumbra + caustics.

float hash21(float2 p) {
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float noise2D(float2 p) {
    float2 i = floor(p);
    float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

float fbm(float2 p) {
    float val = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; i++) {
        val += amp * noise2D(p);
        p *= 2.0;
        amp *= 0.5;
    }
    return val;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;
    float2 pixelPos = uv * resolution;

    if (iMouse.x <= 0.0 && iMouse.y <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);

    // Light source is directly above the window center, high up
    float2 windowCenter = resolution * 0.5;
    float lightHeight = 800.0;  // virtual height above surface

    // Vector from window center to cursor
    float2 fromCenter = iMouse - windowCenter;
    float centerDist = length(fromCenter);

    // Perspective projection: spot elongates away from center
    // The further from center, the more oblique the angle, the more elongated
    float obliqueness = centerDist / lightHeight;
    float elongation = 1.0 + obliqueness * obliqueness * 2.0;

    // Direction of elongation (radial from center)
    float2 elongDir = (centerDist > 1.0) ? fromCenter / centerDist : float2(1.0, 0.0);
    float2 perpDir = float2(-elongDir.y, elongDir.x);

    // Decompose pixel offset from cursor into parallel and perpendicular components
    float2 delta = pixelPos - iMouse;
    float paraComp = dot(delta, elongDir);
    float perpComp = dot(delta, perpDir);

    // Elliptical distance
    float ellipseDist = sqrt(
        (paraComp * paraComp) / (elongation * elongation) +
        perpComp * perpComp
    );

    // Base radius: grows with speed (shaky hand), grows slightly at edges (spread)
    float baseRadius = 140.0
        + smoothstep(0.0, 1500.0, iMouseSpeed) * 80.0
        + obliqueness * 30.0;

    // Noise-distorted edge for organic feel
    float angle = atan2(delta.y, delta.x);
    float edgeNoise = fbm(float2(angle * 2.5 + time * 0.3, centerDist * 0.01 + time * 0.2));
    float noisyRadius = baseRadius * (0.9 + edgeNoise * 0.2);

    // Main light cone
    float light = smoothstep(noisyRadius, noisyRadius * 0.2, ellipseDist);

    // Penumbra: soft outer ring (the "almost lit" zone)
    float penumbra = smoothstep(noisyRadius * 1.4, noisyRadius * 0.8, ellipseDist);

    // Inverse-square falloff from light source (dimmer at edges of window)
    float lightDist = sqrt(centerDist * centerDist + lightHeight * lightHeight);
    float invSqFalloff = (lightHeight * lightHeight) / (lightDist * lightDist);

    // Caustic pattern — subtle undulating light concentrations
    float2 caustUV = pixelPos * 0.01 + float2(time * 0.08, time * -0.06);
    float c1 = sin(caustUV.x * 5.0 + sin(caustUV.y * 3.0 + time * 0.5));
    float c2 = sin(caustUV.y * 4.0 + cos(caustUV.x * 2.5 + time * 0.3));
    float caustic = (c1 * c2 * 0.5 + 0.5);
    caustic = pow(caustic, 2.0) * 0.15 * light;

    // Chromatic fringe at penumbra edge
    float fringeR = smoothstep(noisyRadius * 1.08, noisyRadius * 0.2, ellipseDist);
    float fringeB = smoothstep(noisyRadius * 0.92, noisyRadius * 0.2, ellipseDist);

    // Color: warm spotlight with natural tint
    float3 col = float3(
        (fringeR * 0.9 + caustic) * invSqFalloff,
        (light * 0.85 + caustic * 0.8) * invSqFalloff,
        (fringeB * 0.75 + caustic * 0.5) * invSqFalloff
    );

    // Subtle ambient boost in penumbra zone
    col += float3(0.03, 0.03, 0.05) * (penumbra - light);

    float alpha = (penumbra * 0.15 + light * 0.15 + caustic * 0.2) * invSqFalloff;
    if (alpha < 0.001) return float4(0.0, 0.0, 0.0, 0.0);

    return AT_PostProcess(col, alpha);
}
