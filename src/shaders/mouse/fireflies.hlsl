// Fireflies — Bioluminescent particles that dance around the cursor (compute + pixel)
// Fireflies are attracted to the cursor but have their own wandering behavior.
// They pulse with warm yellow-green bioluminescence and leave brief afterglow trails.

#define MAX_PARTICLES 128

struct Particle {
    float2 pos;       // position in pixels
    float2 vel;       // velocity in px/sec
    float life;       // 0→1 normalized lifetime (>=1 = dead)
    float size;       // radius in pixels
    float heat;       // repurposed: glow phase offset (for pulsing)
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
        // Low spawn rate — fireflies are few and precious
        float spawnRoll = hash2(float2(fi, time * 30.0));
        float spawnRate = 0.01 + smoothstep(0.0, 300.0, iMouseSpeed) * 0.02;
        if (spawnRoll > spawnRate) return;

        float seed = hash1(fi * 17.3);
        float seed2 = hash2(float2(fi, floor(time * 3.0)));
        float seed3 = hash1(fi * 43.7 + 7.0);

        // Spawn near cursor with wider spread
        float angle = seed * 6.2831853;
        float dist = 20.0 + seed2 * 80.0;
        p.pos = iMouse + float2(cos(angle), sin(angle)) * dist;

        // Random initial velocity — fireflies dart erratically
        float vAngle = seed3 * 6.2831853;
        float vSpeed = 30.0 + seed * 50.0;
        p.vel = float2(cos(vAngle), sin(vAngle)) * vSpeed;

        p.size = 3.0 + seed * 3.0;  // small — fireflies are tiny
        p.life = 0.0;
        p.heat = seed * 6.2831853;  // random glow phase
        p.flags = 1;

        particles[idx] = p;
        return;
    }

    // --- PHYSICS UPDATE ---
    float lifetime = 2.0 + hash1(fi * 17.3) * 2.0;  // 2-4 seconds

    // Gentle attraction toward cursor
    float2 toCursor = iMouse - p.pos;
    float cursorDist = length(toCursor);
    if (cursorDist > 1.0) {
        float attraction = 20.0 / max(cursorDist * 0.01, 1.0);
        p.vel += normalize(toCursor) * attraction * timeDelta;
    }

    // Wandering: organic noise-based steering
    float wanderTime = time * 0.5 + fi * 0.1;
    float2 noisePos = p.pos * 0.003 + float2(wanderTime, wanderTime * 0.7);
    float nx = noise1(noisePos) - 0.5;
    float ny = noise1(noisePos + float2(31.7, 47.3)) - 0.5;
    p.vel += float2(nx, ny) * 200.0 * timeDelta;

    // Periodic direction changes (dart behavior)
    float dartPhase = sin(time * 3.0 + fi * 7.0);
    if (dartPhase > 0.95) {
        float dartAngle = hash1(fi + floor(time * 3.0)) * 6.2831853;
        p.vel += float2(cos(dartAngle), sin(dartAngle)) * 40.0 * timeDelta;
    }

    // Speed limit — fireflies don't zoom
    float speed = length(p.vel);
    if (speed > 80.0) p.vel *= 80.0 / speed;

    // Light drag
    p.vel *= (1.0 - 1.0 * timeDelta);

    p.pos += p.vel * timeDelta;

    // Keep fireflies somewhat near the cursor (soft boundary)
    float2 fromCursor = p.pos - iMouse;
    float distFromCursor = length(fromCursor);
    if (distFromCursor > 250.0) {
        p.vel -= normalize(fromCursor) * (distFromCursor - 250.0) * 0.5 * timeDelta;
    }

    // Age
    p.life += timeDelta / lifetime;

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

        float radius = p.size;
        if (dist > radius * 4.0) continue;

        // Pulsing bioluminescence — each firefly has its own rhythm
        float pulseFreq = 2.0 + hash1((float)i * 13.7) * 3.0;  // 2-5 Hz
        float pulse = sin(time * pulseFreq + p.heat);
        pulse = pulse * 0.5 + 0.5;
        pulse = pulse * pulse;  // sharper on/off

        // Soft glow with bright core
        float innerGlow = exp(-dist * dist / (radius * radius * 0.3));
        float outerGlow = exp(-dist * dist / (radius * radius * 2.0));

        float glow = innerGlow * 0.8 + outerGlow * 0.4;
        glow *= pulse;

        // Fade in/out over lifetime
        float fade = smoothstep(0.0, 0.05, p.life) * smoothstep(1.0, 0.8, p.life);
        glow *= fade;

        // Firefly color: warm yellow-green with slight variation per firefly
        float hueShift = hash1((float)i * 23.1) * 0.3;  // 0-0.3
        float3 flyCol = lerp(
            float3(0.6, 1.0, 0.2),    // yellow-green
            float3(0.3, 0.9, 0.5),    // blue-green
            hueShift
        );

        // Brighter when pulsing strongly
        flyCol = lerp(flyCol * 0.5, flyCol * 1.2, pulse);

        col += flyCol * glow;
        totalA += glow * 0.6;
    }

    totalA = saturate(totalA);
    if (totalA < 0.001) return float4(0.0, 0.0, 0.0, 0.0);

    return AT_PostProcess(col, totalA * 0.5);
}
