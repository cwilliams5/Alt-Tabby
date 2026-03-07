// Ember Trail Long — Longer-lived particles with grid splatting (compute + pixel)
// Grid splatting: CS accumulates particle glow onto a 1024x512 grid for O(1) PS.

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

[numthreads(64, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID) {
    uint idx = dtid.x;
    if (idx >= maxParticles + gridW * gridH) return;

    if (idx < maxParticles) {
        Particle p = particles[idx];
        float fi = (float)idx;

        if (p.life >= 1.0) {
            if (iMouseSpeed < 40.0) return;
            float spawnRoll = hash2(float2(fi, time * 60.0));
            float spawnRate = smoothstep(40.0, 600.0, iMouseSpeed * reactivity) * 0.035;
            if (spawnRoll > spawnRate) return;

            float2 velDir = float2(0.0, -1.0);
            if (iMouseSpeed > 1.0) velDir = iMouseVel / iMouseSpeed;
            float seed = hash1(fi * 17.3);
            float seed2 = hash2(float2(fi, floor(time * 5.0)));

            p.pos = iMouse;
            float scatter = (seed2 - 0.5) * 2.0;
            float2 perpDir = float2(-velDir.y, velDir.x);
            float ejectSpeed = (150.0 + seed * 300.0) * reactivity;
            p.vel = -velDir * ejectSpeed + perpDir * scatter * 150.0;
            p.size = 6.0 + seed * 6.0;
            p.life = 0.0;
            p.heat = 1.0;
            p.flags = 1;
            particles[idx] = p;
            return;
        }

        float lifetime = 2.5 + hash1(fi * 17.3) * 2.0;
        p.vel.y += 120.0 * timeDelta;
        p.vel *= (1.0 - 0.8 * timeDelta);
        p.pos += p.vel * timeDelta;
        p.life += timeDelta / lifetime;
        p.heat = saturate(1.0 - p.life);

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
            float radius = p.size * (1.0 - p.life * 0.5);
            float limit = radius * 1.5;
            if (distSq > limit * limit) continue;
            float dist = sqrt(distSq);

            float glow = smoothstep(radius, 0.0, dist);
            glow *= smoothstep(1.0, 0.2, p.life);

            float3 emberCol = lerp(
                float3(1.0, 0.9, 0.5),
                lerp(float3(1.0, 0.4, 0.1), float3(0.6, 0.1, 0.0), p.life),
                p.life
            );

            accCol += emberCol * glow;
            accA += glow;
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
    return AT_PostProcess(val.rgb, val.a * 0.8);
}
