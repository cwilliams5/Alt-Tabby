// Fireflies — Bioluminescent particles that dance around the cursor (compute + pixel)
// Grid splatting: CS accumulates firefly glow onto a 1024x512 grid for O(1) PS.

struct Particle {
    float2 pos;
    float2 vel;
    float life;
    float size;
    float heat;
    uint flags;
};

// ========================= COMPUTE SHADER =========================

RWStructuredBuffer<Particle> particles : register(u0);

float hash1(float n) { return frac(sin(n * 127.1) * 43758.5453); }
float hash2(float2 p) { return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

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
    if (idx >= maxParticles + gridW * gridH) return;

    if (idx < maxParticles) {
        Particle p = particles[idx];
        float fi = (float)idx;

        if (p.life >= 1.0) {
            float spawnRoll = hash2(float2(fi, time * 30.0));
            float spawnRate = 0.01 + smoothstep(0.0, 300.0, iMouseSpeed * reactivity) * 0.02;
            if (spawnRoll > spawnRate) return;

            float seed = hash1(fi * 17.3);
            float seed2 = hash2(float2(fi, floor(time * 3.0)));
            float seed3 = hash1(fi * 43.7 + 7.0);

            float angle = seed * 6.2831853;
            float dist = 20.0 + seed2 * 80.0;
            float sa, ca; sincos(angle, sa, ca);
            p.pos = iMouse + float2(ca, sa) * dist;

            float vAngle = seed3 * 6.2831853;
            float vSpeed = 30.0 + seed * 50.0;
            float sv, cv; sincos(vAngle, sv, cv);
            p.vel = float2(cv, sv) * vSpeed;

            p.size = 3.0 + seed * 3.0;
            p.life = 0.0;
            p.heat = seed * 6.2831853;
            p.flags = 1;

            particles[idx] = p;
            return;
        }

        float lifetime = 2.0 + hash1(fi * 17.3) * 2.0;

        float2 toCursor = iMouse - p.pos;
        float cursorDist = length(toCursor);
        if (cursorDist > 1.0) {
            float attraction = 20.0 * reactivity / max(cursorDist * 0.01, 1.0);
            p.vel += toCursor / cursorDist * attraction * timeDelta;
        }

        float wanderTime = time * 0.5 + fi * 0.1;
        float2 noisePos = p.pos * 0.003 + float2(wanderTime, wanderTime * 0.7);
        float nx = noise1(noisePos) - 0.5;
        float ny = noise1(noisePos + float2(31.7, 47.3)) - 0.5;
        p.vel += float2(nx, ny) * 200.0 * timeDelta;

        float dartPhase = sin(time * 3.0 + fi * 7.0);
        if (dartPhase > 0.95) {
            float dartAngle = hash1(fi + floor(time * 3.0)) * 6.2831853;
            float sd, cd; sincos(dartAngle, sd, cd);
            p.vel += float2(cd, sd) * 40.0 * timeDelta;
        }

        float speed = length(p.vel);
        if (speed > 80.0) p.vel *= 80.0 / speed;

        p.vel *= (1.0 - 1.0 * timeDelta);
        p.pos += p.vel * timeDelta;

        float2 fromCursor = p.pos - iMouse;
        float distFromCursor = length(fromCursor);
        if (distFromCursor > 250.0) {
            p.vel -= fromCursor / distFromCursor * (distFromCursor - 250.0) * 0.5 * timeDelta;
        }

        p.life += timeDelta / lifetime;

        if (p.life >= 1.0 || p.pos.x < -100 || p.pos.x > resolution.x + 100
            || p.pos.y < -100 || p.pos.y > resolution.y + 100) {
            p.life = 1.0;
            p.flags = 0;
        }

        particles[idx] = p;

    } else {
        uint gridIdx = idx - maxParticles;
        int2 gc = int2(gridIdx % gridW, gridIdx / gridW);
        float2 cellPos = (float2(gc) + 0.5) / float2((float)gridW, (float)gridH) * resolution;

        float3 accCol = float3(0, 0, 0);
        float accA = 0;

        for (uint i = 0; i < maxParticles; i++) {
            Particle p = particles[i];
            if (p.life >= 1.0) continue;

            float2 delta = cellPos - p.pos;
            float distSq = dot(delta, delta);
            float radius = p.size;
            float radiusSq = radius * radius;
            if (distSq > radiusSq * 16.0) continue;

            // Pulsing bioluminescence
            float pulseFreq = 2.0 + hash1((float)i * 13.7) * 3.0;
            float pulse = sin(time * pulseFreq + p.heat);
            pulse = pulse * 0.5 + 0.5;
            pulse = pulse * pulse;

            // Dual-layer glow
            float innerGlow = exp(-distSq / (radiusSq * 0.3));
            float outerGlow = exp(-distSq / (radiusSq * 2.0));
            float glow = innerGlow * 0.8 + outerGlow * 0.4;
            glow *= pulse;

            // Fade in/out
            float fade = smoothstep(0.0, 0.05, p.life) * smoothstep(1.0, 0.8, p.life);
            glow *= fade;

            // Firefly color with per-particle hue variation
            float hueShift = hash1((float)i * 23.1) * 0.3;
            float3 flyCol = lerp(
                float3(0.6, 1.0, 0.2),
                float3(0.3, 0.9, 0.5),
                hueShift
            );
            flyCol = lerp(flyCol * 0.5, flyCol * 1.2, pulse);

            accCol += flyCol * glow;
            accA += glow * 0.6;
        }

        Particle cell;
        cell.pos = float2(accCol.r, accCol.g);
        cell.vel = float2(accCol.b, saturate(accA));
        cell.life = 0; cell.size = 0; cell.heat = 0; cell.flags = 0;
        particles[idx] = cell;
    }
}

// ========================= PIXEL SHADER =========================

StructuredBuffer<Particle> particlesRead : register(t4);

float4 sampleGrid(float2 uv) {
    float2 gp = uv * float2((float)gridW, (float)gridH) - 0.5;
    int2 g = int2(floor(gp));
    float2 f = frac(gp);
    g = clamp(g, int2(0, 0), int2(gridW - 2, gridH - 2));
    uint i00 = maxParticles + (uint)g.y * gridW + (uint)g.x;
    float4 c00 = float4(particlesRead[i00].pos, particlesRead[i00].vel);
    float4 c10 = float4(particlesRead[i00+1].pos, particlesRead[i00+1].vel);
    float4 c01 = float4(particlesRead[i00+gridW].pos, particlesRead[i00+gridW].vel);
    float4 c11 = float4(particlesRead[i00+gridW+1].pos, particlesRead[i00+gridW+1].vel);
    return lerp(lerp(c00, c10, f.x), lerp(c01, c11, f.x), f.y);
}

float4 PSMain(PSInput input) : SV_Target {
    float4 val = sampleGrid(input.uv);
    if (val.a < 0.001) return float4(0, 0, 0, 0);
    return AT_PostProcess(val.rgb, val.a * 0.5);
}
