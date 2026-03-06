// Smoke Trail — Wispy smoke puffs that billow and dissipate from cursor movement (compute + pixel)
// Compute shader spawns smoke puffs at cursor. Each puff expands, rises gently, and fades.
// Pixel shader renders volumetric-looking soft blobs with turbulent edges.

#define MAX_PARTICLES 128

struct Particle {
    float2 pos;       // position in pixels
    float2 vel;       // velocity in px/sec
    float life;       // 0→1 normalized lifetime (>=1 = dead)
    float size;       // current radius in pixels
    float heat;       // repurposed: initial size multiplier
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

float noise1(float2 p) {
    float2 i = floor(p);
    float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash2(i);
    float b = hash2(i + float2(1.0, 0.0));
    float c = hash2(i + float2(0.0, 1.0));
    float d = hash2(i + float2(1.0, 1.0));
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

[numthreads(64, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID) {
    uint idx = dtid.x;
    if (idx >= MAX_PARTICLES) return;

    Particle p = particles[idx];
    float fi = (float)idx;

    if (p.life >= 1.0) {
        // --- SPAWN CHECK ---
        if (iMouseSpeed < 25.0) return;

        // Very low spawn rate — smoke puffs are big, fewer needed
        float spawnRoll = hash2(float2(fi, time * 60.0));
        float spawnRate = smoothstep(25.0, 400.0, iMouseSpeed) * 0.025;
        if (spawnRoll > spawnRate) return;

        float seed = hash1(fi * 17.3);
        float seed2 = hash2(float2(fi, floor(time * 5.0)));

        // Spawn slightly behind cursor
        float2 velDir = float2(0.0, -1.0);
        if (iMouseSpeed > 1.0) velDir = iMouseVel / iMouseSpeed;

        p.pos = iMouse - velDir * (5.0 + seed * 15.0);
        p.pos += float2((seed2 - 0.5) * 10.0, (seed - 0.5) * 10.0);

        // Smoke drifts slowly, mostly upward
        p.vel = float2((seed2 - 0.5) * 30.0, -(20.0 + seed * 30.0));

        // Start bigger — fewer puffs means each needs more coverage
        p.size = 15.0 + seed * 12.0;
        p.heat = 1.0 + seed2 * 0.5;  // size multiplier
        p.life = 0.0;
        p.flags = 1;

        particles[idx] = p;
        return;
    }

    // --- PHYSICS UPDATE ---
    float lifetime = 1.2 + hash1(fi * 17.3) * 1.0;  // 1.2-2.2s (shorter — recycle faster)

    // Gentle upward drift (buoyancy)
    p.vel.y -= 8.0 * timeDelta;

    // Turbulence
    float2 noisePos = p.pos * 0.005 + float2(time * 0.4, time * 0.3);
    float nx = noise1(noisePos) - 0.5;
    float ny = noise1(noisePos + float2(31.7, 47.3)) - 0.5;
    p.vel += float2(nx, ny) * 80.0 * timeDelta;

    // Heavy drag — smoke decelerates fast
    p.vel *= (1.0 - 2.0 * timeDelta);

    p.pos += p.vel * timeDelta;

    // Smoke EXPANDS over time — faster expansion since puffs are shorter-lived
    p.size += 45.0 * timeDelta * p.heat;

    // Age
    p.life += timeDelta / lifetime;

    if (p.life >= 1.0 || p.pos.x < -300 || p.pos.x > resolution.x + 300
        || p.pos.y < -300 || p.pos.y > resolution.y + 300) {
        p.life = 1.0;
        p.flags = 0;
    }

    particles[idx] = p;
}

// ========================= PIXEL SHADER =========================

StructuredBuffer<Particle> particlesRead : register(t4);

float pnoise(float2 p) {
    float2 i = floor(p);
    float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = frac(sin(dot(i, float2(127.1, 311.7))) * 43758.5453);
    float b = frac(sin(dot(i + float2(1,0), float2(127.1, 311.7))) * 43758.5453);
    float c = frac(sin(dot(i + float2(0,1), float2(127.1, 311.7))) * 43758.5453);
    float d = frac(sin(dot(i + float2(1,1), float2(127.1, 311.7))) * 43758.5453);
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

float fbm(float2 p) {
    float val = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; i++) {
        val += amp * pnoise(p);
        p *= 2.0;
        amp *= 0.5;
    }
    return val;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 pixelPos = input.uv * resolution;

    float totalA = 0.0;
    float3 col = float3(0.0, 0.0, 0.0);

    for (uint i = 0; i < MAX_PARTICLES; i++) {
        Particle p = particlesRead[i];
        if (p.life >= 1.0) continue;

        float dist = length(pixelPos - p.pos);
        float radius = p.size;
        if (dist > radius * 2.0) continue;

        // Turbulent edge using noise
        float2 dir = (pixelPos - p.pos) / max(radius, 1.0);
        float edgeNoise = fbm(dir * 3.0 + float2(time * 0.3, (float)i * 1.7));
        float noisyDist = dist + edgeNoise * radius * 0.3;

        // Soft gaussian blob
        float smoke = exp(-noisyDist * noisyDist / (radius * radius * 0.4));

        // Fade in quickly, fade out slowly
        float fadeIn = smoothstep(0.0, 0.05, p.life);
        float fadeOut = 1.0 - p.life * p.life;  // slow fade
        smoke *= fadeIn * fadeOut;

        // Smoke is light gray, slightly warm
        float3 smokeCol = float3(0.7, 0.7, 0.72);

        // Darker at the core, lighter at edges (volumetric illusion)
        float coreShade = 0.6 + 0.4 * smoothstep(0.0, radius, dist);
        smokeCol *= coreShade;

        col += smokeCol * smoke * 0.4;
        totalA += smoke * 0.5;
    }

    totalA = saturate(totalA);
    if (totalA < 0.001) return float4(0.0, 0.0, 0.0, 0.0);

    return AT_PostProcess(col, totalA * 0.4);
}
