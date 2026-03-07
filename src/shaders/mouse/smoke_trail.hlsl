// Smoke Trail — Wispy smoke puffs with turbulent edges and grid splatting (compute + pixel)
// Grid splatting: CS accumulates smoke density onto a 1024x512 grid for O(1) PS.

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

float fbm(float2 p) {
    float val = 0.0;
    float amp = 0.5;
    for (int j = 0; j < 4; j++) {
        val += amp * noise1(p);
        p *= 2.0;
        amp *= 0.5;
    }
    return val;
}

[numthreads(64, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID) {
    uint idx = dtid.x;
    if (idx >= maxParticles + gridW * gridH) return;

    if (idx < maxParticles) {
        Particle p = particles[idx];
        float fi = (float)idx;

        if (p.life >= 1.0) {
            if (iMouseSpeed < 25.0) return;
            float spawnRoll = hash2(float2(fi, time * 60.0));
            float spawnRate = smoothstep(25.0, 400.0, iMouseSpeed * reactivity) * 0.025;
            if (spawnRoll > spawnRate) return;

            float seed = hash1(fi * 17.3);
            float seed2 = hash2(float2(fi, floor(time * 5.0)));

            float2 velDir = float2(0.0, -1.0);
            if (iMouseSpeed > 1.0) velDir = iMouseVel / iMouseSpeed;
            p.pos = iMouse - velDir * (5.0 + seed * 15.0);
            p.pos += float2((seed2 - 0.5) * 10.0, (seed - 0.5) * 10.0);
            p.vel = float2((seed2 - 0.5) * 30.0, -(20.0 + seed * 30.0)) * reactivity;
            p.size = 15.0 + seed * 12.0;
            p.heat = 1.0 + seed2 * 0.5;
            p.life = 0.0;
            p.flags = 1;
            particles[idx] = p;
            return;
        }

        float lifetime = 1.2 + hash1(fi * 17.3) * 1.0;
        p.vel.y -= 8.0 * timeDelta;
        float2 noisePos = p.pos * 0.005 + float2(time * 0.4, time * 0.3);
        float nx = noise1(noisePos) - 0.5;
        float ny = noise1(noisePos + float2(31.7, 47.3)) - 0.5;
        p.vel += float2(nx, ny) * 80.0 * timeDelta;
        p.vel *= (1.0 - 2.0 * timeDelta);
        p.pos += p.vel * timeDelta;
        p.size += 45.0 * timeDelta * p.heat;
        p.life += timeDelta / lifetime;

        if (p.life >= 1.0 || p.pos.x < -300 || p.pos.x > resolution.x + 300
            || p.pos.y < -300 || p.pos.y > resolution.y + 300) {
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
            float limit = radius * 2.0;
            if (distSq > limit * limit) continue;
            float dist = sqrt(distSq);

            float2 dir = delta / max(radius, 1.0);
            float edgeNoise = fbm(dir * 3.0 + float2(time * 0.3, (float)i * 1.7));
            float noisyDist = dist + edgeNoise * radius * 0.3;

            float smoke = exp(-noisyDist * noisyDist / (radius * radius * 0.4));
            float fadeIn = smoothstep(0.0, 0.05, p.life);
            float fadeOut = 1.0 - p.life * p.life;
            smoke *= fadeIn * fadeOut;

            float3 smokeCol = float3(0.7, 0.7, 0.72);
            float coreShade = 0.6 + 0.4 * smoothstep(0.0, radius, dist);
            smokeCol *= coreShade;

            accCol += smokeCol * smoke * 0.4;
            accA += smoke * 0.5;
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
    return AT_PostProcess(val.rgb, val.a * 0.4);
}
