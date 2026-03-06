// Liquid — Organic: fluid/molten border animation via noise displacement, metallic sheen

float hash(float2 p) {
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float noise(float2 p) {
    float2 i = floor(p);
    float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);

    float a = hash(i);
    float b = hash(i + float2(1.0, 0.0));
    float c = hash(i + float2(0.0, 1.0));
    float d = hash(i + float2(1.0, 1.0));

    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

float roundedRectSDF(float2 p, float2 center, float2 halfSize, float radius) {
    float2 d = abs(p - center) - halfSize + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 pixelPos = input.uv * resolution;

    float2 rectCenter = selRect.xy + selRect.zw * 0.5;
    float2 halfSize = selRect.zw * 0.5;
    float radius = min(halfSize.x, halfSize.y) * 0.15;

    // Noise-displaced border
    float noiseScale = 0.04;
    float n = noise(pixelPos * noiseScale + float2(time * 0.3, time * 0.2));
    float n2 = noise(pixelPos * noiseScale * 2.0 + float2(-time * 0.2, time * 0.35));
    float displacement = (n * 2.0 - 1.0) * 3.0 + (n2 * 2.0 - 1.0) * 1.5;

    float dist = roundedRectSDF(pixelPos, rectCenter, halfSize, radius);
    float displacedDist = dist + displacement;

    float fill = smoothstep(1.0, -1.0, dist);

    // Liquid border with displacement
    float borderMask = smoothstep(borderWidth + 2.0, borderWidth - 1.0, abs(displacedDist));

    // Metallic sheen — varies along the border
    float perim = atan2(pixelPos.y - rectCenter.y, pixelPos.x - rectCenter.x);
    float sheen = sin(perim * 3.0 + time * 1.5) * 0.5 + 0.5;

    // Shadow
    float2 shadowCenter = rectCenter + float2(0.0, 2.5);
    float shadowDist = roundedRectSDF(pixelPos, shadowCenter, halfSize + 5.0, radius + 2.0);
    float shadow = smoothstep(0.0, 14.0, -shadowDist) * 0.25;

    float t = smoothstep(0.0, 1.0, entranceT);
    float intensity = lerp(1.0, 0.5, isHovered);

    float3 col = float3(0.0, 0.0, 0.0);
    float a = shadow * t * intensity;

    // Fill
    float fillA = fill * selColor.a * t * intensity;
    col = selColor.rgb;
    a = max(a, fillA);

    // Metallic border
    float3 sheenBorder = lerp(borderColor.rgb, borderColor.rgb * 1.5, sheen);
    float borderA = borderMask * borderColor.a * t * intensity;
    col = lerp(col, sheenBorder, saturate(borderA));
    a = max(a, borderA);

    a = saturate(a);
    return float4(col * a, a) * opacity;
}
