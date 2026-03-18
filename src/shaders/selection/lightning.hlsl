// Lightning Selection — Electric arcs crackling across the border

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

    // Perimeter coordinate for arcs
    float perim = (px.x - selRect.x + px.y - selRect.y) / (selRect.z + selRect.w);

    // Electric arcs — noise-displaced border creates jagged bolts
    float arc = 0.0;
    for (int i = 0; i < 3; i++) {
        float fi = (float)i;
        // Each bolt has its own phase and flash timing
        float flashRate = 3.0 + fi * 1.5;
        float flashT = frac(time * flashRate * 0.3 + fi * 0.37);
        float envelope = smoothstep(0.0, 0.03, flashT) * smoothstep(0.25, 0.08, flashT);

        // Noise displacement — jagged path
        float nL = vnoise(float2(perim * 10.0 + fi * 7.0, time * flashRate));
        float nS = vnoise(float2(perim * 25.0 + fi * 13.0, time * flashRate * 1.5 + 50.0));
        float displacement = (nL - 0.5) * 8.0 + (nS - 0.5) * 4.0;

        // Distance from jagged border
        float jDist = abs(dist + displacement);
        float bolt = smoothstep(3.0, 0.0, jDist) * envelope;

        // Branch arcs — secondary bolts forking inward
        float branchSeed = floor(time * flashRate + fi * 0.37);
        float branchPos = hash(float2(branchSeed, fi * 53.0));
        float branchDist = abs(perim - branchPos);
        float branchWrap = min(branchDist, 1.0 - branchDist);
        float branch = smoothstep(0.08, 0.0, branchWrap) * envelope;
        float branchInward = smoothstep(0.0, -15.0, dist) * fill;
        branch *= branchInward;

        arc += (bolt + branch * 0.6) * (0.6 + fi * 0.2);
    }
    arc = saturate(arc);

    float3 col = float3(0, 0, 0);
    float a = 0.0;

    // Fill with user color
    float fillA = fill * selColor.a * tI;
    col = selColor.rgb;
    a = fillA;

    // Electric arcs — bright cyan-white
    float3 boltCol = float3(0.6, 0.85, 1.0);
    float3 coreCol = float3(0.9, 0.95, 1.0);
    float3 arcCol = lerp(boltCol, coreCol, arc);
    col += arcCol * arc * 0.8 * tIS;
    a = max(a, arc * 0.7 * tIS);

    // Ambient electric glow on border
    float glow = smoothstep(6.0 * selGlow, 0.0, abs(dist)) * 0.2;
    float flicker = 0.7 + 0.3 * sin(time * 8.0);
    col += boltCol * glow * flicker * tIS;
    a = max(a, glow * flicker * 0.5 * tIS);

    // Border
    float borderA = borderMask * borderColor.a * tI;
    float3 borderMix = lerp(borderColor.rgb, boltCol * 0.5, 0.3 * selIntensity);
    col = lerp(col, borderMix, borderA);
    a = max(a, borderA);

    return AT_PostProcess(col, saturate(a));
}
