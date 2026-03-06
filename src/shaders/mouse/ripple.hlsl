// Ripple — Motion-triggered concentric waves with wall-bounce reflections
// Ripples only appear when mouse is moving. Waves reflect off overlay edges
// via mirror-source technique for convincing wall bouncing.

float rippleField(float2 pixelPos, float2 center, float t) {
    float dist = length(pixelPos - center);
    float wave = sin(dist * 0.05 - t * 4.0) * 0.5 + 0.5;
    float fade = smoothstep(400.0, 0.0, dist);
    return wave * fade * fade;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;
    float2 p = uv * resolution;

    if (iMouse.x <= 0.0 && iMouse.y <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);

    // Speed gate: ripples only appear when mouse is moving
    float speedNorm = smoothstep(50.0, 400.0, iMouseSpeed);
    if (speedNorm < 0.001)
        return float4(0.0, 0.0, 0.0, 0.0);

    float t = time;
    float radius = 400.0;

    // Primary ripple from cursor
    float field = rippleField(p, iMouse, t);

    // Wall-bounce mirror sources (only compute when cursor is near wall)
    float2 res = resolution;
    if (iMouse.x < radius)
        field = max(field, rippleField(p, float2(-iMouse.x, iMouse.y), t));
    if (iMouse.x > res.x - radius)
        field = max(field, rippleField(p, float2(2.0 * res.x - iMouse.x, iMouse.y), t));
    if (iMouse.y < radius)
        field = max(field, rippleField(p, float2(iMouse.x, -iMouse.y), t));
    if (iMouse.y > res.y - radius)
        field = max(field, rippleField(p, float2(iMouse.x, 2.0 * res.y - iMouse.y), t));

    // Velocity-scaled intensity
    float intensity = field * speedNorm;

    // Cool blue-white tint
    float3 col = float3(0.5, 0.6, 1.0) * intensity;

    return AT_PostProcess(col, intensity * 0.5);
}
