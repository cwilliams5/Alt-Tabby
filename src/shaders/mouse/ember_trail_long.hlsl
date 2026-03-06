// Ember Trail Long — Same physics as Ember Trail but longer-lived particles (compute + pixel)
// Embers linger longer, arcing further and fading through the full color gradient.
// Lower spawn rate compensates for longer lifetime to avoid pool starvation.

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

        // Lower spawn rate to match ~3x longer lifetime
        float spawnRoll = hash2(float2(fi, time * 60.0));
        float spawnRate = smoothstep(40.0, 600.0, iMouseSpeed) * 0.035;
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
    float lifetime = 2.5 + hash1(fi * 17.3) * 2.0;  // 2.5-4.5s

    // Softer gravity — embers arc longer before falling
    p.vel.y += 120.0 * timeDelta;

    // More drag — embers slow down and float
    p.vel *= (1.0 - 0.8 * timeDelta);

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
