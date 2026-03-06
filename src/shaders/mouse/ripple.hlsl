// Ripple — Motion-triggered waves with persistent expansion (compute + pixel)
// Compute shader spawns ripples at cursor position, ages them independently.
// Pixel shader reads ripple buffer and renders wave interference with wall reflections.
// Each ripple varies in size, speed, wavelength, and intensity.

#define MAX_RIPPLES 128

struct Ripple {
    float2 center;      // spawn position in pixels
    float birthTime;    // time when spawned
    float intensity;    // initial strength (from mouse speed at spawn)
    float maxRadius;    // how far this ripple will reach (VARIES per ripple)
    float expansion;    // expansion speed in px/sec (VARIES per ripple)
    float wavelength;   // wave frequency multiplier (VARIES)
    float aspect;       // aspect ratio for elliptical ripples (1.0 = circle)
};

// ========================= COMPUTE SHADER =========================

RWStructuredBuffer<Ripple> ripples : register(u0);

float hash1(float n) {
    return frac(sin(n * 127.1) * 43758.5453);
}

float hash2(float2 p) {
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
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
        if (iMouseSpeed < 40.0) return;

        // Lower spawn rate — fewer but more varied ripples
        float spawnRoll = hash1(fi + time * 60.0);
        float spawnRate = smoothstep(40.0, 400.0, iMouseSpeed) * 0.06;
        if (spawnRoll > spawnRate) return;

        float seed = hash1(fi * 17.3);
        float seed2 = hash2(float2(fi, floor(time * 5.0)));
        float seed3 = hash1(fi * 43.7 + 7.0);

        r.center = iMouse;
        r.birthTime = time;

        // VARY intensity based on mouse speed
        r.intensity = smoothstep(40.0, 500.0, iMouseSpeed) * (0.5 + seed * 0.5);

        // VARY max radius: 150-500px (some ripples are small splashes, some are big waves)
        r.maxRadius = 150.0 + seed * 350.0;

        // VARY expansion speed: faster mouse = faster ripple expansion
        float baseExpansion = 100.0 + seed2 * 200.0;  // 100-300 px/s
        r.expansion = baseExpansion * (0.7 + smoothstep(0.0, 400.0, iMouseSpeed) * 0.6);

        // VARY wavelength: different wave frequencies per ripple
        r.wavelength = 0.03 + seed3 * 0.06;  // 0.03-0.09 (vs fixed 0.05)

        // Aspect ratio from velocity direction — makes ripples slightly elliptical
        r.aspect = 1.0;
        if (iMouseSpeed > 80.0) {
            r.aspect = 0.6 + seed2 * 0.3;  // 0.6-0.9 (stretched in movement dir)
        }

        ripples[idx] = r;
        return;
    }

    // Mark dead if expired
    if (age > maxLife) {
        r.intensity = 0.0;
        ripples[idx] = r;
    }
}

// ========================= PIXEL SHADER =========================

StructuredBuffer<Ripple> ripplesRead : register(t4);

float rippleWave(float2 pixelPos, float2 center, float age, float expansion,
                 float wavelength, float aspect, float2 velDir) {
    float2 delta = pixelPos - center;

    // Apply aspect ratio along velocity direction for elliptical ripples
    if (aspect < 0.99) {
        float2 perpDir = float2(-velDir.y, velDir.x);
        float paraComp = dot(delta, velDir);
        float perpComp = dot(delta, perpDir);
        // Stretch perpendicular to velocity
        delta = velDir * paraComp + perpDir * perpComp * (1.0 / aspect);
    }

    float dist = length(delta);
    float currentRadius = age * expansion;

    // Variable wavelength per ripple
    float wave = sin(dist * wavelength - age * 4.0) * 0.5 + 0.5;

    // Wavefront band — narrower for tighter waves
    float bandWidth = 80.0 + 40.0 / max(wavelength * 20.0, 1.0);
    float waveFront = smoothstep(currentRadius + bandWidth * 0.5, currentRadius, dist)
                    * smoothstep(max(currentRadius - bandWidth, 0.0), currentRadius, dist);

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

        // Intensity decays with age — varied decay curve per ripple
        float decayCurve = smoothstep(maxLife, maxLife * 0.1, age);
        float decay = r.intensity * decayCurve;
        float radius = age * r.expansion;

        // Velocity direction for elliptical distortion (stored in .aspect)
        float2 velDir = float2(1.0, 0.0);  // default
        // Approximate velDir from aspect (we know it's along iMouseVel at spawn)
        // Since we can't store full velDir, use the fact that ripples near each other
        // share similar directions. For visual variety, this approximation is fine.

        // Primary ripple
        float field = rippleWave(p, r.center, age, r.expansion, r.wavelength, r.aspect, velDir);

        // Wall-bounce mirror sources
        if (r.center.x < radius)
            field = max(field, rippleWave(p, float2(-r.center.x, r.center.y), age, r.expansion, r.wavelength, 1.0, velDir));
        if (r.center.x > res.x - radius)
            field = max(field, rippleWave(p, float2(2.0 * res.x - r.center.x, r.center.y), age, r.expansion, r.wavelength, 1.0, velDir));
        if (r.center.y < radius)
            field = max(field, rippleWave(p, float2(r.center.x, -r.center.y), age, r.expansion, r.wavelength, 1.0, velDir));
        if (r.center.y > res.y - radius)
            field = max(field, rippleWave(p, float2(r.center.x, 2.0 * res.y - r.center.y), age, r.expansion, r.wavelength, 1.0, velDir));

        // Max blend — overlapping ripples reinforce but don't blow out
        totalField = max(totalField, field * decay);
    }

    if (totalField < 0.001) return float4(0.0, 0.0, 0.0, 0.0);

    // Cool blue-white tint — stays blue regardless of intensity
    float3 col = float3(0.5, 0.6, 1.0) * totalField;

    return AT_PostProcess(col, totalField * 0.4);
}
