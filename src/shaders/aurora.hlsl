// Aurora — 3 colored blobs in slow elliptical orbits with soft falloff
// Organic non-circular motion via phase-offset sine/cosine

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;
    float aspect = resolution.x / resolution.y;
    float aspectFactor = aspect / max(aspect, 1.0);
    float2 center = float2(0.5, 0.5);

    float t = time * 0.15;

    // Three blobs with elliptical orbits (different phase, eccentricity)
    float2 p1 = center + float2(
        0.25 * sin(t * 1.1 + 0.0) * aspectFactor,
        0.20 * cos(t * 0.9 + 1.5)
    );
    float2 p2 = center + float2(
        0.22 * sin(t * 0.8 + 2.1) * aspectFactor,
        0.28 * cos(t * 1.2 + 0.8)
    );
    float2 p3 = center + float2(
        0.30 * sin(t * 0.7 + 4.0) * aspectFactor,
        0.18 * cos(t * 1.05 + 3.2)
    );

    // Adjust UV for aspect ratio
    float2 auv = float2(uv.x * aspectFactor, uv.y);
    float2 ap1 = float2(p1.x * aspectFactor, p1.y);
    float2 ap2 = float2(p2.x * aspectFactor, p2.y);
    float2 ap3 = float2(p3.x * aspectFactor, p3.y);

    // Soft distance fields
    float d1 = smoothstep(0.35, 0.0, length(auv - ap1));
    float d2 = smoothstep(0.35, 0.0, length(auv - ap2));
    float d3 = smoothstep(0.35, 0.0, length(auv - ap3));

    // Colors: magenta, blue, purple
    float3 c1 = float3(0.85, 0.15, 0.55);
    float3 c2 = float3(0.20, 0.40, 0.90);
    float3 c3 = float3(0.55, 0.20, 0.80);

    float3 col = c1 * d1 + c2 * d2 + c3 * d3;

    return AT_PostProcess(col);
}
