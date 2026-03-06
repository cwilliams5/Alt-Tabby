// Ember Trail — Faint particles drifting upward from cursor position

float hash(float2 p) {
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;
    float2 pixelPos = uv * resolution;

    if (iMouse.x <= 0.0 && iMouse.y <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);

    float3 col = float3(0.0, 0.0, 0.0);
    float totalA = 0.0;

    // Simulate several particle layers
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float t = time * (0.8 + fi * 0.15);

        // Particle position: rises from cursor with slight wobble
        float2 particleBase = iMouse;
        float age = frac(t * 0.3 + fi * 0.166);
        float2 offset = float2(
            sin(t + fi * 2.4) * 15.0,
            -age * 120.0 // rise upward
        );
        float2 pPos = particleBase + offset;

        float dist = length(pixelPos - pPos);
        float size = 8.0 + fi * 3.0;

        float particle = smoothstep(size, 0.0, dist);

        // Fade out as particle ages
        float lifeFade = smoothstep(1.0, 0.3, age) * smoothstep(0.0, 0.1, age);
        particle *= lifeFade;

        // Warm ember colors
        float3 emberCol = lerp(
            float3(1.0, 0.4, 0.1),
            float3(1.0, 0.8, 0.3),
            hash(float2(fi, 0.0))
        );

        col += emberCol * particle;
        totalA += particle;
    }

    totalA = saturate(totalA);

    return AT_PostProcess(col, totalA * 0.6);
}
