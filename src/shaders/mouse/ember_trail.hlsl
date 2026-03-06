// Ember Trail — Velocity-directed particles with gravity
// Embers eject opposite to mouse movement, fall with gravity, fade over lifetime.
// Speed-gated: no embers when mouse is stationary.

float hash1(float n) {
    return frac(sin(n * 127.1) * 43758.5453);
}

float hash2(float2 p) {
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;
    float2 p = uv * resolution;

    if (iMouse.x <= 0.0 && iMouse.y <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);

    float speed = iMouseSpeed;
    float speedNorm = smoothstep(30.0, 800.0, speed);

    // No embers when stationary
    if (speedNorm < 0.001)
        return float4(0.0, 0.0, 0.0, 0.0);

    // Velocity direction (normalized), fallback to upward
    float2 velDir = float2(0.0, -1.0);
    if (speed > 1.0)
        velDir = iMouseVel / speed;

    float3 col = float3(0.0, 0.0, 0.0);
    float totalA = 0.0;

    // 8 particles in the trail
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        float seed = hash1(fi * 17.3);

        // Independent lifecycle per particle
        float cycleLen = 0.8 + seed * 0.6;  // 0.8-1.4s lifetime
        float phase = frac(time / cycleLen + seed);
        float age = phase;  // 0→1 over lifetime

        // Spawn position: trail behind cursor along velocity direction
        float trailDist = (fi * 0.12 + seed * 0.08) * speed * 0.06;
        float2 spawnPos = iMouse - velDir * trailDist;

        // Ejection: opposite to velocity with perpendicular scatter
        float scatter = (hash2(float2(fi, floor(time / cycleLen))) - 0.5) * 2.0;
        float2 perpDir = float2(-velDir.y, velDir.x);
        float2 ejectVel = -velDir * (20.0 + seed * 40.0) + perpDir * scatter * 30.0;

        // Gravity pulls particles downward (screen Y increases downward)
        float2 gravity = float2(0.0, 80.0);

        // Position at current age
        float t = age * cycleLen;
        float2 particlePos = spawnPos + ejectVel * t + 0.5 * gravity * t * t;

        // Size shrinks with age, bigger at higher speed
        float baseSize = 5.0 + speedNorm * 6.0;
        float size = baseSize * (1.0 - age * 0.7);

        float dist = length(p - particlePos);
        float particle = smoothstep(size, size * 0.2, dist);

        // Fade: ramp in quickly, fade out over lifetime
        float lifeFade = smoothstep(0.0, 0.05, age) * smoothstep(1.0, 0.4, age);
        particle *= lifeFade * speedNorm;

        // Ember color: hot white-yellow → orange → dark red over lifetime
        float3 emberCol = lerp(
            float3(1.0, 0.9, 0.5),
            lerp(float3(1.0, 0.4, 0.1), float3(0.6, 0.1, 0.0), age),
            age
        );

        col += emberCol * particle;
        totalA += particle;
    }

    totalA = saturate(totalA);
    return AT_PostProcess(col, totalA * 0.7);
}
