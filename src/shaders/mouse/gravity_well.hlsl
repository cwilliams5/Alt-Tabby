// Gravity Well — Particles orbit cursor like a miniature galaxy (compute + pixel)
// Particles spiral around the cursor with gravitational attraction and tangential velocity.
// Fast cursor movement scatters particles; stillness lets them settle into orbits.

#define MAX_PARTICLES 128

struct Particle {
    float2 pos;       // position in pixels
    float2 vel;       // velocity in px/sec
    float life;       // 0→1 normalized lifetime (>=1 = dead)
    float size;       // radius in pixels
    float heat;       // brightness / color warmth
    uint flags;       // bit 0: active
};

// ========================= COMPUTE SHADER =========================

RWStructuredBuffer<Particle> particles : register(u0);

float hash1(float n) {
    return frac(sin(n * 127.1) * 43758.5453);
}

float hash2(float2 p) {
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

[numthreads(64, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID) {
    uint idx = dtid.x;
    if (idx >= MAX_PARTICLES) return;

    Particle p = particles[idx];
    float fi = (float)idx;

    if (p.life >= 1.0) {
        // --- SPAWN ---
        // Low spawn rate — orbiting particles are visible a long time
        float spawnRoll = hash2(float2(fi, time * 30.0));
        float spawnRate = 0.01 + smoothstep(0.0, 300.0, iMouseSpeed) * 0.02;
        if (spawnRoll > spawnRate) return;

        float seed = hash1(fi * 17.3);
        float seed2 = hash2(float2(fi, floor(time * 3.0)));
        float seed3 = hash1(fi * 43.7 + 7.0);

        // Spawn in a ring around cursor
        float angle = seed * 6.2831853;
        float spawnDist = 30.0 + seed2 * 100.0;
        p.pos = iMouse + float2(cos(angle), sin(angle)) * spawnDist;

        // Initial tangential velocity (orbital)
        float2 radial = normalize(p.pos - iMouse);
        float2 tangent = float2(-radial.y, radial.x);
        float orbitalSpeed = 60.0 + seed3 * 80.0;
        p.vel = tangent * orbitalSpeed;

        // Add some of cursor velocity for scatter effect
        if (iMouseSpeed > 50.0) {
            p.vel += iMouseVel * 0.3;
        }

        p.size = 2.0 + seed * 3.0;
        p.heat = 0.5 + seed2 * 0.5;
        p.life = 0.0;
        p.flags = 1;

        particles[idx] = p;
        return;
    }

    // --- PHYSICS UPDATE ---
    float lifetime = 2.0 + hash1(fi * 17.3) * 2.0;  // 2-4s

    float2 toMouse = iMouse - p.pos;
    float r = max(length(toMouse), 15.0);

    // Gravitational attraction — inverse square with softening
    float G = 8000.0;
    // Weaken gravity when cursor is moving fast (scatter effect)
    float gravityMod = 1.0 / (1.0 + iMouseSpeed * 0.003);
    float accelMag = G * gravityMod / (r * r);
    accelMag = min(accelMag, 500.0);  // cap acceleration

    float2 accel = normalize(toMouse) * accelMag;
    p.vel += accel * timeDelta;

    // Very slight drag to prevent runaway orbits
    p.vel *= (1.0 - 0.3 * timeDelta);

    p.pos += p.vel * timeDelta;

    // Heat based on speed (fast = hot)
    float speed = length(p.vel);
    p.heat = saturate(speed / 200.0);

    // Age
    p.life += timeDelta / lifetime;

    if (p.life >= 1.0 || p.pos.x < -200 || p.pos.x > resolution.x + 200
        || p.pos.y < -200 || p.pos.y > resolution.y + 200) {
        p.life = 1.0;
        p.flags = 0;
    }

    particles[idx] = p;
}

// ========================= PIXEL SHADER =========================

StructuredBuffer<Particle> particlesRead : register(t4);

float4 PSMain(PSInput input) : SV_Target {
    float2 pixelPos = input.uv * resolution;

    float3 col = float3(0.0, 0.0, 0.0);
    float totalA = 0.0;

    for (uint i = 0; i < MAX_PARTICLES; i++) {
        Particle p = particlesRead[i];
        if (p.life >= 1.0) continue;

        float dist = length(pixelPos - p.pos);
        float radius = p.size;
        if (dist > radius * 4.0) continue;

        // Core + glow
        float core = exp(-dist * dist / (radius * radius * 0.3));
        float glow = exp(-dist * dist / (radius * radius * 2.0));

        float brightness = core * 0.8 + glow * 0.3;

        // Fade in/out
        float fade = smoothstep(0.0, 0.05, p.life) * smoothstep(1.0, 0.8, p.life);
        brightness *= fade;

        // Color: cool blue for slow particles, warm yellow for fast
        float3 coolCol = float3(0.3, 0.5, 1.0);   // blue
        float3 warmCol = float3(1.0, 0.8, 0.3);   // warm yellow
        float3 hotCol = float3(1.0, 1.0, 0.9);     // white-hot

        float3 particleCol;
        if (p.heat < 0.5)
            particleCol = lerp(coolCol, warmCol, p.heat * 2.0);
        else
            particleCol = lerp(warmCol, hotCol, (p.heat - 0.5) * 2.0);

        col += particleCol * brightness;
        totalA += brightness * 0.5;
    }

    totalA = saturate(totalA);
    if (totalA < 0.001) return float4(0.0, 0.0, 0.0, 0.0);

    return AT_PostProcess(col, totalA * 0.5);
}
