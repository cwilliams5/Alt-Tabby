// Radial Glow — Soft warm light falloff centered on cursor

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;
    float2 pixelPos = uv * resolution;

    // No effect until mouse moves
    if (iMouse.x <= 0.0 && iMouse.y <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);

    float dist = length(pixelPos - iMouse);
    float radius = 120.0;

    // Soft falloff
    float glow = smoothstep(radius, 0.0, dist);
    glow *= glow; // quadratic for softer edges

    // Warm light color
    float3 col = float3(1.0, 0.85, 0.6) * glow;

    return AT_PostProcess(col, glow);
}
