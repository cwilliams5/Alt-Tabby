// Lava Selection — Flowing molten lava with glowing cracks

float hash(float2 p) {
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float2 hash2(float2 p) {
    return float2(
        frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453),
        frac(sin(dot(p, float2(269.5, 183.3))) * 43758.5453));
}

// Animated Voronoi — returns (cell distance, edge distance)
float2 voronoi(float2 p) {
    float2 n = floor(p);
    float2 f = frac(p);
    float md = 8.0;
    float md2 = 8.0;
    float timePhase = time * 0.4;
    for (int j = -1; j <= 1; j++)
    for (int i = -1; i <= 1; i++) {
        float2 g = float2((float)i, (float)j);
        float2 o = hash2(n + g);
        o = 0.5 + 0.4 * sin(timePhase + 6.28318 * o); // slow animation
        float2 r = g + o - f;
        float d = dot(r, r);
        if (d < md) { md2 = md; md = d; }
        else if (d < md2) { md2 = d; }
    }
    float sqrtMd = sqrt(md);
    return float2(sqrtMd, sqrt(md2) - sqrtMd); // cell dist, edge dist
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

    // Local UV scaled for lava cells
    float2 luv = (px - selRect.xy) / selRect.zw;
    float aspect = selRect.z / max(selRect.w, 1.0);
    float2 vor_uv = float2(luv.x * aspect, luv.y) * 4.0;
    vor_uv.x += time * 0.08; // slow horizontal flow

    float2 v = voronoi(vor_uv);
    float cellDist = v.x;
    float edgeDist = v.y;

    // Cracks glow bright — narrow bright lines between cells
    float crack = smoothstep(0.15, 0.0, edgeDist);

    // Cell interior — darker, cooling lava
    float cellFade = smoothstep(0.0, 0.4, cellDist);

    // Lava palette: bright orange cracks, dark red cells
    float3 hotCol = float3(1.0, 0.6, 0.1);   // bright orange
    float3 warmCol = float3(0.8, 0.2, 0.05);  // dark red

    float3 lavaCol = lerp(hotCol, warmCol, cellFade);
    lavaCol = lerp(lavaCol, hotCol * 1.5, crack); // cracks glow hot

    // Pulsing heat
    float pulse = 0.85 + 0.15 * sin(time * 1.5 + cellDist * 5.0);
    lavaCol *= pulse;

    float3 col = float3(0, 0, 0);
    float a = 0.0;

    // Lava fill — blends user color with lava pattern
    float lavaAlpha = fill * 0.85 * tI;
    float3 baseFill = lerp(selColor.rgb, lavaCol * selColor.a, 0.6 * selIntensity);
    col = baseFill;
    a = max(selColor.a * fill, lavaAlpha) * tI;

    // Hot glow on cracks extends slightly outside
    float outerHeat = smoothstep(4.0 * selGlow, 0.0, dist) * (1.0 - fill) * crack * 0.4;
    col += hotCol * outerHeat * tIS;
    a = max(a, outerHeat * tIS);

    // Border — hot edge
    float3 borderMix = lerp(borderColor.rgb, hotCol * 0.5, 0.4 * selIntensity);
    float borderA = borderMask * borderColor.a * tI;
    col = lerp(col, borderMix, saturate(borderA));
    a = max(a, borderA);

    return AT_PostProcess(col, saturate(a));
}
