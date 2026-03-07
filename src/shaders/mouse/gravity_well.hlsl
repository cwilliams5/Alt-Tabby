// Gravity Well — Particles orbit cursor like a miniature galaxy (compute + pixel)
// Grid splatting: CS accumulates orbital glow onto a 1024x512 grid for O(1) PS.

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
            float spawnRoll = hash2(float2(fi, time * 30.0));
            float spawnRate = 0.01 + smoothstep(0.0, 300.0, iMouseSpeed * reactivity) * 0.02;
            if (spawnRoll > spawnRate) return;

            float seed = hash1(fi * 17.3);
            float seed2 = hash2(float2(fi, floor(time * 3.0)));
            float seed3 = hash1(fi * 43.7 + 7.0);

            float angle = seed * 6.2831853;
            float spawnDist = 30.0 + seed2 * 100.0;
            float sa, ca; sincos(angle, sa, ca);
            p.pos = iMouse + float2(ca, sa) * spawnDist;

            float2 radial = normalize(p.pos - iMouse);
            float2 tangent = float2(-radial.y, radial.x);
            float orbitalSpeed = 60.0 + seed3 * 80.0;
            p.vel = tangent * orbitalSpeed;

            if (iMouseSpeed > 50.0) {
                p.vel += iMouseVel * 0.3;
            }

            p.size = 2.0 + seed * 3.0;
            p.heat = 0.5 + seed2 * 0.5;
            p.life = 0.0;
            p.flags = 1;

            particles[idx] = p;
            return;
        }

        float lifetime = 2.0 + hash1(fi * 17.3) * 2.0;

        float2 toMouse = iMouse - p.pos;
        float r = max(length(toMouse), 15.0);

        float G = 8000.0 * reactivity;
        float gravityMod = 1.0 / (1.0 + iMouseSpeed * 0.003);
        float accelMag = G * gravityMod / (r * r);
        accelMag = min(accelMag, 500.0);

        float2 accel = normalize(toMouse) * accelMag;
        p.vel += accel * timeDelta;

        p.vel *= (1.0 - 0.3 * timeDelta);
        p.pos += p.vel * timeDelta;

        float speed = length(p.vel);
        p.heat = saturate(speed / 200.0);

        p.life += timeDelta / lifetime;

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
            float radius = p.size;
            float limit = radius * 4.0;
            if (distSq > limit * limit) continue;

            // Core + glow
            float radiusSq = radius * radius;
            float core = exp(-distSq / (radiusSq * 0.3));
            float glow = exp(-distSq / (radiusSq * 2.0));
            float brightness = core * 0.8 + glow * 0.3;

            // Fade in/out
            float fade = smoothstep(0.0, 0.05, p.life) * smoothstep(1.0, 0.8, p.life);
            brightness *= fade;

            // Color: cool blue → warm yellow → white-hot based on speed
            float3 coolCol = float3(0.3, 0.5, 1.0);
            float3 warmCol = float3(1.0, 0.8, 0.3);
            float3 hotCol = float3(1.0, 1.0, 0.9);

            float3 particleCol;
            if (p.heat < 0.5)
                particleCol = lerp(coolCol, warmCol, p.heat * 2.0);
            else
                particleCol = lerp(warmCol, hotCol, (p.heat - 0.5) * 2.0);

            accCol += particleCol * brightness;
            accA += brightness * 0.5;
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
