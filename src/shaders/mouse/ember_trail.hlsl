// Ember Trail — Velocity-directed particles with gravity (compute + pixel)
// Compute shader manages 128 particles with independent physics.
// Pixel shader reads particle buffer and renders soft glowing circles.

#define MAX_PARTICLES 128

struct Particle {
    float2 pos;       // position in pixels
    float2 vel;       // velocity in px/sec
    float life;       // 0→1 normalized lifetime (>=1 = dead)
    float size;       // radius in pixels
    float heat;       // 1.0 = hot white, 0.0 = cold dark
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
        // --- SPAWN CHECK ---
        if (iMouseSpeed < 40.0) return;

        // Low spawn rate — ~10% at full speed, keeps particles sparse
        float spawnRoll = hash2(float2(fi, time * 60.0));
        float spawnRate = smoothstep(40.0, 600.0, iMouseSpeed) * 0.10;
        if (spawnRoll > spawnRate) return;

        // Velocity direction
        float2 velDir = float2(0.0, -1.0);
        if (iMouseSpeed > 1.0)
            velDir = iMouseVel / iMouseSpeed;

        float seed = hash1(fi * 17.3);
        float seed2 = hash2(float2(fi, floor(time * 5.0)));

        // Spawn at cursor
        p.pos = iMouse;

        // Eject HARD opposite to velocity with wide scatter
        float scatter = (seed2 - 0.5) * 2.0;
        float2 perpDir = float2(-velDir.y, velDir.x);
        float ejectSpeed = 150.0 + seed * 300.0;
        p.vel = -velDir * ejectSpeed + perpDir * scatter * 150.0;

        p.size = 6.0 + seed * 6.0;
        p.life = 0.0;
        p.heat = 1.0;
        p.flags = 1;

        particles[idx] = p;
        return;
    }

    // --- PHYSICS UPDATE ---
    float lifetime = 1.0 + hash1(fi * 17.3) * 0.8;  // 1.0-1.8s

    // Strong gravity
    p.vel.y += 200.0 * timeDelta;

    // Light drag — let particles fly
    p.vel *= (1.0 - 0.5 * timeDelta);

    // Integrate position
    p.pos += p.vel * timeDelta;

    // Age
    p.life += timeDelta / lifetime;

    // Heat tracks inverse life
    p.heat = saturate(1.0 - p.life);

    // Kill if expired or far off-screen
    if (p.life >= 1.0 || p.pos.x < -100 || p.pos.x > resolution.x + 100
        || p.pos.y < -100 || p.pos.y > resolution.y + 100) {
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

        // Radius shrinks over lifetime
        float radius = p.size * (1.0 - p.life * 0.5);
        if (dist > radius * 1.5) continue;

        float glow = smoothstep(radius, 0.0, dist);

        // Fade over lifetime
        glow *= smoothstep(1.0, 0.2, p.life);

        // Ember color: hot white-yellow → orange → dark red
        float3 emberCol = lerp(
            float3(1.0, 0.9, 0.5),
            lerp(float3(1.0, 0.4, 0.1), float3(0.6, 0.1, 0.0), p.life),
            p.life
        );

        col += emberCol * glow;
        totalA += glow;
    }

    totalA = saturate(totalA);
    if (totalA < 0.001) return float4(0.0, 0.0, 0.0, 0.0);

    return AT_PostProcess(col, totalA * 0.8);
}
