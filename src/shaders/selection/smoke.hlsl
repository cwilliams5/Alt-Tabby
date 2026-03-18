// Smoke Selection — Rising wisps of ethereal smoke curling through the selection

float hash(float2 p) {
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    return lerp(
        lerp(hash(i), hash(i + float2(1, 0)), f.x),
        lerp(hash(i + float2(0, 1)), hash(i + float2(1, 1)), f.x),
        f.y);
}

float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * vnoise(p);
        p = p * 2.0 + float2(100, 0);
        a *= 0.5;
    }
    return v;
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
    float tI = t * intensity;
    float tIS = tI * selIntensity;

    // Local UV for smoke
    float2 luv = (px - selRect.xy) / selRect.zw;

    // Rising smoke — 3 layers scrolling upward at different speeds
    float s1 = fbm(luv * float2(4.0, 3.0) + float2(time * 0.03, -time * 0.15));
    float s2 = fbm(luv * float2(6.0, 4.0) + float2(-time * 0.05, -time * 0.25));
    float s3 = fbm(luv * float2(9.0, 6.0) + float2(time * 0.07, -time * 0.4));

    float smoke = s1 * 0.5 + s2 * 0.3 + s3 * 0.2;
    float wisp = smoothstep(0.3, 0.55, smoke) * fill;

    float3 col = float3(0, 0, 0);
    float a = 0.0;

    // Fill with user color
    float fillA = fill * selColor.a * tI;
    col = selColor.rgb;
    a = fillA;

    // Bright smoke overlay — white wisps
    float3 smokeCol = float3(0.7, 0.75, 0.85);
    col += smokeCol * wisp * 0.5 * tIS;
    a = max(a, wisp * 0.3 * tIS);

    // Outer glow
    float outerGlow = smoothstep(8.0 * selGlow, 0.0, dist) * (1.0 - fill) * 0.15;
    col += smokeCol * outerGlow * tIS;
    a = max(a, outerGlow * tIS);

    // Border
    float borderA = borderMask * borderColor.a * tI;
    col = lerp(col, borderColor.rgb, borderA);
    a = max(a, borderA);

    return AT_PostProcess(col, saturate(a));
}
