// Scatter — Ambient dust motes that scatter away from the cursor (compute + pixel)
// The overlay feels alive with floating particles that react to mouse proximity.
// Particles flee when the cursor approaches, then gently drift back home.

#define MAX_PARTICLES 384

struct Particle {
    float2 pos;       // position in pixels
    float2 vel;       // velocity in px/sec
    float life;       // 0→1 normalized lifetime (>=1 = dead)
    float size;       // radius in pixels
    float heat;       // brightness variation
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

// Deterministic home position from particle index — always the same for a given slot
float2 homePos(float fi, float2 res) {
    float hx = hash1(fi * 17.3);
    float hy = hash2(float2(fi, 31.7));
    // Inset from edges so home is always visible
    return float2(
        40.0 + hx * (res.x - 80.0),
        40.0 + hy * (res.y - 80.0)
    );
}

[numthreads(64, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID) {
    uint idx = dtid.x;
    if (idx >= MAX_PARTICLES) return;

    Particle p = particles[idx];
    float fi = (float)idx;

    if (p.life >= 1.0) {
        // --- SPAWN: place at home position ---
        // High spawn rate — we want the screen populated quickly
        float spawnRoll = hash2(float2(fi, time * 10.0));
        if (spawnRoll > 0.30) return;

        float seed3 = hash1(fi * 43.7 + 7.0);

        // Spawn at deterministic home position
        p.pos = homePos(fi, resolution);
        p.vel = float2(0.0, 0.0);

        p.size = 2.5 + seed3 * 3.0;
        p.life = 0.0;
        p.heat = 0.4 + hash1(fi * 91.3) * 0.6;  // brightness
        p.flags = 1;

        particles[idx] = p;
        return;
    }

    // --- PHYSICS UPDATE ---
    // Immortal until pushed way off-screen — they live and resettle
    float lifetime = 30.0;  // very long — effectively permanent

    // Repulsion from cursor
    float2 fromCursor = p.pos - iMouse;
    float cursorDist = length(fromCursor);
    float repelRadius = 100.0 + iMouseSpeed * 0.4;

    if (cursorDist < repelRadius && cursorDist > 1.0) {
        float repelForce = (1.0 - cursorDist / repelRadius);
        repelForce = repelForce * repelForce * repelForce;
        float pushStrength = 500.0 + iMouseSpeed * 2.5;
        p.vel += normalize(fromCursor) * repelForce * pushStrength * timeDelta;
    }

    // HOME PULL — gentle spring force back toward home position
    float2 home = homePos(fi, resolution);
    float2 toHome = home - p.pos;
    float homeDist = length(toHome);
    if (homeDist > 1.0) {
        // Stronger pull the further from home, but never overpowering
        float pullStrength = 15.0 + homeDist * 0.1;
        p.vel += normalize(toHome) * pullStrength * timeDelta;
    }

    // Gentle ambient drift (floating dust feel)
    float2 noisePos = p.pos * 0.002 + float2(time * 0.1, time * 0.08);
    float nx = noise1(noisePos) - 0.5;
    float ny = noise1(noisePos + float2(31.7, 47.3)) - 0.5;
    p.vel += float2(nx, ny) * 10.0 * timeDelta;

    // Drag — decelerate after being pushed
    p.vel *= (1.0 - 2.5 * timeDelta);

    p.pos += p.vel * timeDelta;

    // Kill only if extremely far off-screen (shouldn't happen with home pull)
    if (p.pos.x < -200 || p.pos.x > resolution.x + 200
        || p.pos.y < -200 || p.pos.y > resolution.y + 200) {
        p.life = 1.0;  // will respawn at home next frame
        p.flags = 0;
    }

    // Age (very slow — effectively permanent particles)
    p.life += timeDelta / lifetime;

    if (p.life >= 1.0) {
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
        if (dist > radius * 3.5) continue;

        // Soft glow
        float glow = exp(-dist * dist / (radius * radius * 0.6));

        // Subtle shimmer
        float shimmer = 0.8 + 0.2 * sin(time * 2.0 + (float)i * 4.7);
        glow *= shimmer;

        // Brighter when displaced from home (shows they've been disturbed)
        float fi = (float)i;
        float2 home = float2(
            40.0 + frac(sin(fi * 127.1) * 43758.5453) * (resolution.x - 80.0),
            40.0 + frac(sin(dot(float2(fi, 31.7), float2(127.1, 311.7))) * 43758.5453) * (resolution.y - 80.0)
        );
        float displacement = length(p.pos - home);
        float excitedness = smoothstep(0.0, 80.0, displacement);

        // Base brightness + excitement boost
        float brightness = p.heat * (0.7 + excitedness * 0.5);
        glow *= brightness;

        // Soft white-blue-silver — slightly brighter when disturbed
        float colorSeed = frac(sin((float)i * 23.1 * 127.1) * 43758.5453);
        float3 dustCol = lerp(
            float3(0.7, 0.8, 1.0),    // cool silver-blue
            float3(0.9, 0.92, 1.0),   // bright white-blue
            excitedness
        );

        col += dustCol * glow;
        totalA += glow * 0.5;
    }

    totalA = saturate(totalA);
    if (totalA < 0.001) return float4(0.0, 0.0, 0.0, 0.0);

    return AT_PostProcess(col, totalA * 0.4);
}
