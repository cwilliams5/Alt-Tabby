// Rain Selection — Diagonal rain streaks falling through the selection

float roundedRectSDF(float2 p, float2 center, float2 halfSize, float radius) {
    float2 d = abs(p - center) - halfSize + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

float hash(float n) {
    return frac(sin(n) * 43758.5453);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 px = input.uv * resolution;
    float2 rc = selRect.xy + selRect.zw * 0.5;
    float2 hs = selRect.zw * 0.5;
    float rad = min(hs.x, hs.y) * 0.15;
    float dist = roundedRectSDF(px, rc, hs, rad);
    float fill = smoothstep(1.0, -1.0, dist);
    float borderMask = smoothstep(borderWidth + 1.5, borderWidth - 0.5, abs(dist));

    float t = smoothstep(0.0, 1.0, entranceT);
    float intensity = lerp(1.0, 0.45, isHovered);

    float2 luv = (px - selRect.xy) / selRect.zw;

    // Rain — 4 layers of falling streaks at slight angles
    float rain = 0.0;
    for (int i = 0; i < 4; i++) {
        float fi = (float)i;
        float speed = 2.5 + fi * 1.2;
        float tileW = 0.035 + fi * 0.015;
        float tileH = 0.2 + fi * 0.08;

        float2 uv2 = luv / float2(tileW, tileH);
        uv2.y -= time * speed / tileH;
        uv2.x += luv.y * (0.08 + fi * 0.02) / tileW; // slight diagonal

        float2 id = floor(uv2);
        float2 fuv = frac(uv2);

        float h = hash(id.x * 127.0 + id.y * 311.0 + fi * 53.0);
        float starX = 0.3 + h * 0.4;

        float dx = abs(fuv.x - starX);
        float drop = smoothstep(0.08, 0.0, dx) *
                     smoothstep(0.0, 0.15, fuv.y) *
                     smoothstep(1.0, 0.5, fuv.y);
        drop *= 0.3 + fi * 0.15;
        rain += drop;
    }
    rain = saturate(rain) * fill;

    float3 col = float3(0, 0, 0);
    float a = 0.0;

    // Fill with user color
    float fillA = fill * selColor.a * t * intensity;
    col = selColor.rgb;
    a = fillA;

    // Rain overlay — bright blue-white streaks
    float3 rainCol = float3(0.6, 0.8, 1.0);
    col += rainCol * rain * 0.7 * t * intensity * selIntensity;
    a = max(a, rain * 0.5 * t * intensity * selIntensity);

    // Border — rain hitting the border creates drip highlights
    float dripPhase = sin(px.x * 0.3 + time * 3.0) * 0.5 + 0.5;
    float3 borderMix = lerp(borderColor.rgb, rainCol * 0.5, dripPhase * 0.3 * selIntensity);
    float borderA = borderMask * borderColor.a * t * intensity;
    col = lerp(col, borderMix, saturate(borderA));
    a = max(a, borderA);

    // Post-process: darken + desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, (float3)lum, desaturate);
    col *= (1.0 - darken);

    a = saturate(a);
    return float4(col * a, a) * opacity;
}
