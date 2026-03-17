// Neon Trail — Glowing light-painting trail behind cursor (compute + pixel)
// Grid splatting: CS accumulates neon glow onto a 1024x512 grid for O(1) PS.

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

float3 hsv2rgb(float3 c) {
    float3 p = abs(frac(c.xxx + float3(1.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
    return c.z * lerp(float3(1.0, 1.0, 1.0), saturate(p - 1.0), c.y);
}

[numthreads(64, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID) {
    uint idx = dtid.x;
    if (idx >= maxParticles + gridW * gridH) return;

    if (idx < maxParticles) {
        Particle p = particles[idx];

        // Only thread 0 records new position
        if (idx == 0) {
            if (iMouseSpeed * reactivity < 5.0) return;

            // Find oldest slot to overwrite
            float oldestTime = 1e20;
            uint oldestIdx = 0;
            for (uint i = 0; i < maxParticles; i++) {
                Particle check = particles[i];
                if (check.life >= 1.0) {
                    oldestIdx = i;
                    oldestTime = -1.0;
                    break;
                }
                if (check.heat < oldestTime) {
                    oldestTime = check.heat;
                    oldestIdx = i;
                }
            }

            // Minimum distance check
            float minDistSq = 1e20;
            for (uint j = 0; j < maxParticles; j++) {
                if (particles[j].life >= 1.0) continue;
                float2 dd = iMouse - particles[j].pos;
                float dSq = dot(dd, dd);
                if (dSq < minDistSq) minDistSq = dSq;
            }
            if (minDistSq < 16.0) return;

            Particle np;
            np.pos = iMouse;
            np.vel = iMouseVel;
            np.life = 0.0;
            np.size = iMouseSpeed;
            np.heat = time;
            np.flags = 0;

            particles[oldestIdx] = np;
            return;
        }

        // All other threads: age existing points
        if (p.life >= 1.0) return;

        float age = time - p.heat;
        float lifetime = 1.5;

        if (age > lifetime) {
            p.life = 1.0;
            p.flags = 0;
            particles[idx] = p;
        }

    } else {
        uint gridIdx = idx - maxParticles;
        int2 gc = int2(gridIdx % gridW, gridIdx / gridW);
        float2 cellPos = (float2(gc) + 0.5) / float2((float)gridW, (float)gridH) * resolution;

        float3 accCol = float3(0, 0, 0);
        float accA = 0;

        for (uint i = 0; i < maxParticles; i++) {
            Particle p = particles[i];
            if (p.life >= 1.0) continue;

            float age = time - p.heat;
            if (age < 0.0 || age > 1.5) continue;

            float2 delta = cellPos - p.pos;
            float distSq = dot(delta, delta);
            if (distSq > 60.0 * 60.0) continue;

            // Age-based fade
            float fade = 1.0 - age / 1.5;
            fade = fade * fade;

            // Thickness based on speed at recording
            float thickness = 2.0 + smoothstep(0.0, 500.0, p.size) * 4.0;

            // Triple-layer glow
            float norm = distSq / (thickness * thickness);
            float core = exp(-norm);
            float inner = exp(-norm * 0.16667);
            float outer = exp(-norm * 0.05);

            float glow = core * 1.0 + inner * 0.4 + outer * 0.15;
            glow *= fade;

            // Rainbow color based on recording time
            float hue = frac(p.heat * 0.3);
            float3 trailCol = hsv2rgb(float3(hue, 0.8, 1.0));

            // White core
            float3 finalCol = lerp(trailCol, float3(1.0, 1.0, 1.0), core * 0.6);

            accCol += finalCol * glow;
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
    return AT_PostProcess(val.rgb, val.a * 0.6);
}
