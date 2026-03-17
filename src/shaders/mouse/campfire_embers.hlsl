// Campfire Embers — Soft glowing embers with turbulence and grid splatting (compute + pixel)
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
            if (iMouseSpeed < 30.0) return;
            float spawnRoll = hash2(float2(fi, time * 60.0));
            float spawnRate = smoothstep(30.0, 500.0, iMouseSpeed * reactivity) * 0.025;
            if (spawnRoll > spawnRate) return;

            float seed = hash1(fi * 17.3);
            float seed2 = hash2(float2(fi, floor(time * 5.0)));
            float seed3 = hash1(fi * 43.7 + 7.0);

            p.pos = iMouse + float2((seed - 0.5) * 20.0, (seed2 - 0.5) * 20.0);
            float upSpeed = (40.0 + seed * 60.0) * reactivity;
            float lateralDrift = (seed2 - 0.5) * 60.0 * reactivity;
            p.vel = float2(lateralDrift, -upSpeed);
            p.size = 8.0 + seed3 * 10.0;
            p.life = 0.0;
            p.heat = 0.8 + seed * 0.2;
            p.flags = 1;
            particles[idx] = p;
            return;
        }

        float lifetime = 1.2 + hash1(fi * 17.3) * 1.0;
        p.vel.y -= 15.0 * timeDelta;
        float2 noisePos = p.pos * 0.008 + float2(time * 0.3, time * 0.2);
        float nx = noise1(noisePos) - 0.5;
        float ny = noise1(noisePos + float2(31.7, 47.3)) - 0.5;
        p.vel += float2(nx, ny) * 120.0 * timeDelta;
        p.vel *= (1.0 - 1.5 * timeDelta);
        p.pos += p.vel * timeDelta;
        p.life += timeDelta / lifetime;
        p.heat = saturate(0.8 * (1.0 - p.life * p.life));

        if (p.life >= 1.0 || p.pos.x < -200 || p.pos.x > resolution.x + 200
            || p.pos.y < -200 || p.pos.y > resolution.y + 200) {
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
            float pulse = 1.0 + 0.15 * sin(p.life * 12.0 + (float)i * 2.0);
            float radius = p.size * pulse * (1.0 - p.life * 0.3);
            float radiusSq = radius * radius;
            if (distSq > radiusSq * 6.25) continue;
            float glow = exp(-distSq / (radiusSq * 0.5));
            float fadeIn = smoothstep(0.0, 0.1, p.life);
            float fadeOut = smoothstep(1.0, 0.3, p.life);
            glow *= fadeIn * fadeOut;

            float h = p.heat;
            float3 emberCol = lerp(
                float3(0.3, 0.02, 0.0),
                lerp(float3(0.9, 0.2, 0.02), float3(1.0, 0.5, 0.1), h),
                h
            );
            float flicker = 0.85 + 0.15 * sin(time * 8.0 + (float)i * 5.3);
            emberCol *= flicker;

            accCol += emberCol * glow;
            accA += glow * 0.7;
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
    return AT_PostProcess(val.rgb, val.a * 0.6);
}
