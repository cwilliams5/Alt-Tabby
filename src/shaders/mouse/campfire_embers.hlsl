// Campfire Embers — Soft glowing embers that float upward with gentle turbulence (compute + pixel)
// Inspired by "sparks from fire" shader. Embers drift and tumble with organic movement,
// not straight-line trajectories. Softer, rounder glow than the spark-like ember_trail.

#define MAX_PARTICLES 128

struct Particle {
    float2 pos;       // position in pixels
    float2 vel;       // velocity in px/sec
    float life;       // 0→1 normalized lifetime (>=1 = dead)
    float size;       // radius in pixels
    float heat;       // 1.0 = hot, 0.0 = cold
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

// Simplex-style noise for organic turbulence
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
        if (iMouseSpeed < 30.0) return;

        // Low spawn rate — embers are big and visible, don't need many
        float spawnRoll = hash2(float2(fi, time * 60.0));
        float spawnRate = smoothstep(30.0, 500.0, iMouseSpeed) * 0.025;
        if (spawnRoll > spawnRate) return;

        float seed = hash1(fi * 17.3);
        float seed2 = hash2(float2(fi, floor(time * 5.0)));
        float seed3 = hash1(fi * 43.7 + 7.0);

        // Spawn at cursor with slight offset
        p.pos = iMouse + float2((seed - 0.5) * 20.0, (seed2 - 0.5) * 20.0);

        // Embers drift UPWARD with gentle scatter — not hard ejection
        float upSpeed = 40.0 + seed * 60.0;  // 40-100 px/s upward
        float lateralDrift = (seed2 - 0.5) * 60.0;  // gentle side drift
        p.vel = float2(lateralDrift, -upSpeed);  // negative Y = up

        // Larger, softer particles
        p.size = 8.0 + seed3 * 10.0;  // 8-18px radius
        p.life = 0.0;
        p.heat = 0.8 + seed * 0.2;  // start warm, not white-hot
        p.flags = 1;

        particles[idx] = p;
        return;
    }

    // --- PHYSICS UPDATE ---
    // Moderate lifetime — recycle slots so trail doesn't starve
    float lifetime = 1.2 + hash1(fi * 17.3) * 1.0;  // 1.2-2.2s

    // Very gentle upward buoyancy (negative = up on screen)
    p.vel.y -= 15.0 * timeDelta;

    // Organic turbulence: curl-noise-like perturbation
    float2 noisePos = p.pos * 0.008 + float2(time * 0.3, time * 0.2);
    float nx = noise1(noisePos) - 0.5;
    float ny = noise1(noisePos + float2(31.7, 47.3)) - 0.5;
    p.vel += float2(nx, ny) * 120.0 * timeDelta;

    // Gentle drag — embers float, don't fly
    p.vel *= (1.0 - 1.5 * timeDelta);

    // Integrate position
    p.pos += p.vel * timeDelta;

    // Age
    p.life += timeDelta / lifetime;

    // Heat decays with life — slower than ember_trail
    p.heat = saturate(0.8 * (1.0 - p.life * p.life));

    // Kill if expired or far off-screen
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

        // Size grows slightly then shrinks — like an ember pulsing
        float pulse = 1.0 + 0.15 * sin(p.life * 12.0 + (float)i * 2.0);
        float radius = p.size * pulse * (1.0 - p.life * 0.3);
        if (dist > radius * 2.5) continue;

        // Soft, wide glow — not a hard circle
        float glow = exp(-dist * dist / (radius * radius * 0.5));

        // Fade in gently, fade out slowly
        float fadeIn = smoothstep(0.0, 0.1, p.life);
        float fadeOut = smoothstep(1.0, 0.3, p.life);
        glow *= fadeIn * fadeOut;

        // Campfire ember color: deep orange → red → dark cherry
        // Not white-hot like sparks — warm and soft
        float h = p.heat;
        float3 emberCol = lerp(
            float3(0.3, 0.02, 0.0),   // dark cherry (cold/dying)
            lerp(
                float3(0.9, 0.2, 0.02),  // deep orange-red (mid)
                float3(1.0, 0.5, 0.1),   // warm orange (hot)
                h
            ),
            h
        );

        // Add subtle flicker
        float flicker = 0.85 + 0.15 * sin(time * 8.0 + (float)i * 5.3);
        emberCol *= flicker;

        col += emberCol * glow;
        totalA += glow * 0.7;
    }

    totalA = saturate(totalA);
    if (totalA < 0.001) return float4(0.0, 0.0, 0.0, 0.0);

    return AT_PostProcess(col, totalA * 0.6);
}
