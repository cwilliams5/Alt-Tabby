// Scatter — Ambient dust motes that scatter away from the cursor (compute + pixel)
// Grid splatting: CS accumulates dust glow onto a 1024x512 grid for O(1) PS.

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

float2 homePos(float fi, float2 res) {
    float hx = hash1(fi * 17.3);
    float hy = hash2(float2(fi, 31.7));
    return float2(
        40.0 + hx * (res.x - 80.0),
        40.0 + hy * (res.y - 80.0)
    );
}

[numthreads(64, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID) {
    uint idx = dtid.x;
    if (idx >= maxParticles + gridW * gridH) return;

    if (idx < maxParticles) {
        Particle p = particles[idx];
        float fi = (float)idx;

        if (p.life >= 1.0) {
            float spawnRoll = hash2(float2(fi, time * 10.0));
            if (spawnRoll > 0.30) return;

            float seed3 = hash1(fi * 43.7 + 7.0);

            p.pos = homePos(fi, resolution);
            p.vel = float2(0.0, 0.0);
            p.size = 2.5 + seed3 * 3.0;
            p.life = 0.0;
            p.heat = 0.4 + hash1(fi * 91.3) * 0.6;
            p.flags = 1;

            particles[idx] = p;
            return;
        }

        float lifetime = 30.0;

        float2 fromCursor = p.pos - iMouse;
        float cursorDist = length(fromCursor);
        float repelRadius = 100.0 + iMouseSpeed * reactivity * 0.4;

        if (cursorDist < repelRadius && cursorDist > 1.0) {
            float repelForce = (1.0 - cursorDist / repelRadius);
            repelForce = repelForce * repelForce * repelForce;
            float pushStrength = (500.0 + iMouseSpeed * 2.5) * reactivity;
            p.vel += normalize(fromCursor) * repelForce * pushStrength * timeDelta;
        }

        float2 home = homePos(fi, resolution);
        float2 toHome = home - p.pos;
        float homeDist = length(toHome);
        if (homeDist > 1.0) {
            float pullStrength = 15.0 + homeDist * 0.1;
            p.vel += normalize(toHome) * pullStrength * timeDelta;
        }

        float2 noisePos = p.pos * 0.002 + float2(time * 0.1, time * 0.08);
        float nx = noise1(noisePos) - 0.5;
        float ny = noise1(noisePos + float2(31.7, 47.3)) - 0.5;
        p.vel += float2(nx, ny) * 10.0 * timeDelta;

        p.vel *= (1.0 - 2.5 * timeDelta);
        p.pos += p.vel * timeDelta;

        if (p.pos.x < -200 || p.pos.x > resolution.x + 200
            || p.pos.y < -200 || p.pos.y > resolution.y + 200) {
            p.life = 1.0;
            p.flags = 0;
        }

        p.life += timeDelta / lifetime;

        if (p.life >= 1.0) {
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

            float dist = length(cellPos - p.pos);
            float radius = p.size;
            if (dist > radius * 3.5) continue;

            // Soft glow
            float glow = exp(-dist * dist / (radius * radius * 0.6));

            // Subtle shimmer
            float shimmer = 0.8 + 0.2 * sin(time * 2.0 + (float)i * 4.7);
            glow *= shimmer;

            // Displacement-based brightness
            float fi = (float)i;
            float2 home = homePos(fi, resolution);
            float displacement = length(p.pos - home);
            float excitedness = smoothstep(0.0, 80.0, displacement);

            float brightness = p.heat * (0.7 + excitedness * 0.5);
            glow *= brightness;

            // Color: silver-blue, brighter when disturbed
            float3 dustCol = lerp(
                float3(0.7, 0.8, 1.0),
                float3(0.9, 0.92, 1.0),
                excitedness
            );

            accCol += dustCol * glow;
            accA += glow * 0.5;
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
