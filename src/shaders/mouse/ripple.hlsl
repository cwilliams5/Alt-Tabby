// Ripple — Motion-triggered concentric waves with persistent expansion (compute + pixel)
// Compute shader spawns ripples at cursor position, ages them independently.
// Pixel shader reads ripple buffer and renders wave interference with wall reflections.

#define MAX_RIPPLES 128

struct Ripple {
    float2 center;      // spawn position in pixels
    float birthTime;    // time when spawned
    float intensity;    // initial strength (from mouse speed at spawn)
    float maxRadius;    // how far this ripple will reach
    float expansion;    // expansion speed (px/sec)
    float2 pad;         // alignment to 32 bytes
};

// ========================= COMPUTE SHADER =========================

RWStructuredBuffer<Ripple> ripples : register(u0);

float hash1(float n) {
    return frac(sin(n * 127.1) * 43758.5453);
}

[numthreads(64, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID) {
    uint idx = dtid.x;
    if (idx >= MAX_RIPPLES) return;

    Ripple r = ripples[idx];
    float fi = (float)idx;

    // Check if ripple is dead (intensity <= 0 or expired)
    float age = time - r.birthTime;
    float maxLife = r.maxRadius / max(r.expansion, 1.0);
    bool isDead = (r.intensity <= 0.0) || (age > maxLife && r.birthTime > 0.0) || (r.birthTime == 0.0);

    if (isDead) {
        // --- SPAWN CHECK ---
        if (iMouseSpeed < 50.0) return;

        // Stochastic spawn rate: ~5-10 ripples/sec at full speed
        float spawnRoll = hash1(fi + time * 60.0);
        float spawnRate = smoothstep(50.0, 400.0, iMouseSpeed) * 0.25;
        if (spawnRoll > spawnRate) return;

        r.center = iMouse;
        r.birthTime = time;
        r.intensity = smoothstep(50.0, 400.0, iMouseSpeed);
        r.maxRadius = 400.0;
        r.expansion = 200.0;
        r.pad = float2(0.0, 0.0);

        ripples[idx] = r;
        return;
    }

    // Alive ripples don't need per-frame compute updates — aging is done in PS via time
    // But mark dead if expired
    if (age > maxLife) {
        r.intensity = 0.0;
        ripples[idx] = r;
    }
}

// ========================= PIXEL SHADER =========================

StructuredBuffer<Ripple> ripplesRead : register(t4);

float rippleWave(float2 pixelPos, float2 center, float age, float expansion) {
    float dist = length(pixelPos - center);
    float currentRadius = age * expansion;
    float wave = sin(dist * 0.05 - age * 4.0) * 0.5 + 0.5;

    // Fade: strongest at wavefront, fading behind
    float waveFront = smoothstep(currentRadius + 50.0, currentRadius, dist)
                    * smoothstep(max(currentRadius - 150.0, 0.0), currentRadius, dist);
    return wave * waveFront;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;
    float2 p = uv * resolution;
    float2 res = resolution;

    float totalField = 0.0;

    for (uint i = 0; i < MAX_RIPPLES; i++) {
        Ripple r = ripplesRead[i];
        if (r.intensity <= 0.0) continue;

        float age = time - r.birthTime;
        float maxLife = r.maxRadius / max(r.expansion, 1.0);
        if (age > maxLife || age < 0.0) continue;

        // Intensity decays with age
        float decay = r.intensity * smoothstep(maxLife, 0.0, age);
        float radius = age * r.expansion;

        // Primary ripple from spawn center
        float field = rippleWave(p, r.center, age, r.expansion);

        // Wall-bounce mirror sources (only compute when ripple is near wall)
        if (r.center.x < radius)
            field = max(field, rippleWave(p, float2(-r.center.x, r.center.y), age, r.expansion));
        if (r.center.x > res.x - radius)
            field = max(field, rippleWave(p, float2(2.0 * res.x - r.center.x, r.center.y), age, r.expansion));
        if (r.center.y < radius)
            field = max(field, rippleWave(p, float2(r.center.x, -r.center.y), age, r.expansion));
        if (r.center.y > res.y - radius)
            field = max(field, rippleWave(p, float2(r.center.x, 2.0 * res.y - r.center.y), age, r.expansion));

        totalField = max(totalField, field * decay);
    }

    if (totalField < 0.001) return float4(0.0, 0.0, 0.0, 0.0);

    // Cool blue-white tint
    float3 col = float3(0.5, 0.6, 1.0) * totalField;

    return AT_PostProcess(col, totalField * 0.5);
}
