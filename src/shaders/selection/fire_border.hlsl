// Fire Border Selection — Flames licking along the edges of the selection

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

    // Early exit: outside all effect regions (fill + border + outer fire glow)
    if (dist > max(borderWidth + 2.0, 13.0 * selGlow + 1.0))
        return float4(0.0, 0.0, 0.0, 0.0);

    float t = smoothstep(0.0, 1.0, entranceT);
    float intensity = isHovered;
    float tI = t * intensity;
    float tIS = tI * selIntensity;

    float2 luv = (px - selRect.xy) / selRect.zw;

    // Distance from each edge (0 at edge, 1 at opposite)
    float dBottom = luv.y;
    float dTop = 1.0 - luv.y;
    float dLeft = luv.x;
    float dRight = 1.0 - luv.x;

    // Fire noise — scrolls upward (for bottom flames) or downward (for top)
    float aspect = selRect.z / max(selRect.w, 1.0);

    // Bottom flames — largest, most dramatic
    float2 fireUV_B = float2(luv.x * aspect * 5.0, dBottom * 4.0 - time * 2.0);
    float fireB = fbm(fireUV_B);
    float flameB = smoothstep(0.25, 0.0, dBottom - fireB * 0.35) * smoothstep(0.4, 0.0, dBottom);

    // Top flames — smaller, pointing down
    float2 fireUV_T = float2(luv.x * aspect * 5.0, dTop * 4.0 - time * 2.2 + 50.0);
    float fireT = fbm(fireUV_T);
    float flameT = smoothstep(0.20, 0.0, dTop - fireT * 0.25) * smoothstep(0.3, 0.0, dTop);

    // Side flames — subtle
    float2 fireUV_L = float2(luv.y * 4.0, dLeft * 5.0 - time * 1.8 + 100.0);
    float fireL = fbm(fireUV_L);
    float flameL = smoothstep(0.15, 0.0, dLeft - fireL * 0.15) * smoothstep(0.2, 0.0, dLeft);

    float2 fireUV_R = float2(luv.y * 4.0, dRight * 5.0 - time * 1.8 + 150.0);
    float fireR = fbm(fireUV_R);
    float flameR = smoothstep(0.15, 0.0, dRight - fireR * 0.15) * smoothstep(0.2, 0.0, dRight);

    float rawFlame = max(max(flameB, flameT), max(flameL, flameR));
    float flame = rawFlame * fill;

    // Fire palette — white core → yellow → orange → red → dark
    float3 fireCol;
    if (flame > 0.8)
        fireCol = lerp(float3(1.0, 0.9, 0.3), float3(1.0, 1.0, 0.8), (flame - 0.8) * 5.0);
    else if (flame > 0.4)
        fireCol = lerp(float3(1.0, 0.4, 0.05), float3(1.0, 0.9, 0.3), (flame - 0.4) * 2.5);
    else
        fireCol = lerp(float3(0.3, 0.05, 0.0), float3(1.0, 0.4, 0.05), flame * 2.5);

    float3 col = float3(0, 0, 0);
    float a = 0.0;

    // Fill with user color
    float fillA = fill * selColor.a * tI;
    col = selColor.rgb;
    a = fillA;

    // Fire overlay
    col += fireCol * flame * 0.7 * tIS;
    a = max(a, flame * 0.6 * tIS);

    // Outer fire glow — flames extend beyond border
    float outerFire = rawFlame;
    float outerGlow = smoothstep(12.0 * selGlow, 0.0, dist) * (1.0 - fill) * outerFire * 0.5;
    col += float3(1.0, 0.4, 0.05) * outerGlow * tIS;
    a = max(a, outerGlow * tIS);

    // Border — hot edge
    float3 borderMix = lerp(borderColor.rgb, float3(1.0, 0.6, 0.1) * 0.5, 0.4 * selIntensity);
    float borderA = borderMask * borderColor.a * tI;
    col = lerp(col, borderMix, borderA);
    a = max(a, borderA);

    return AT_PostProcess(col, saturate(a));
}
