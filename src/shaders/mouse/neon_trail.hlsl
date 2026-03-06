// Neon Trail — Glowing light-painting trail behind cursor (compute + pixel)
// Compute shader stores cursor position history as a ring buffer.
// Pixel shader renders the polyline trail with intense multi-layer glow and rainbow colors.

#define MAX_PARTICLES 128

struct Particle {
    float2 pos;       // cursor position at this sample
    float2 vel;       // cursor velocity at this sample (for thickness)
    float life;       // 0→1 age (>=1 = unused slot)
    float size;       // speed at recording (for color/thickness)
    float heat;       // timestamp when recorded
    uint flags;       // ring buffer index this was written to
};

// ========================= COMPUTE SHADER =========================

RWStructuredBuffer<Particle> particles : register(u0);

[numthreads(64, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID) {
    uint idx = dtid.x;
    if (idx >= MAX_PARTICLES) return;

    Particle p = particles[idx];

    // Only thread 0 records new position
    if (idx == 0) {
        if (iMouseSpeed < 5.0) return;

        // Find oldest slot to overwrite
        float oldestTime = 1e20;
        uint oldestIdx = 0;
        for (uint i = 0; i < MAX_PARTICLES; i++) {
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

        // Check minimum distance from last recorded point
        // (avoid over-sampling when cursor barely moves)
        float minDist = 1e20;
        for (uint j = 0; j < MAX_PARTICLES; j++) {
            if (particles[j].life >= 1.0) continue;
            float d = length(iMouse - particles[j].pos);
            if (d < minDist) minDist = d;
        }
        if (minDist < 4.0) return;  // too close to existing point

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
    float lifetime = 1.5;  // trail lasts 1.5 seconds

    if (age > lifetime) {
        p.life = 1.0;
        p.flags = 0;
        particles[idx] = p;
    }
}

// ========================= PIXEL SHADER =========================

StructuredBuffer<Particle> particlesRead : register(t4);

float distToSegment(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float t = saturate(dot(p - a, ab) / max(dot(ab, ab), 0.001));
    float2 closest = a + ab * t;
    return length(p - closest);
}

// HSV to RGB
float3 hsv2rgb(float3 c) {
    float3 p = abs(frac(c.xxx + float3(1.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
    return c.z * lerp(float3(1.0, 1.0, 1.0), saturate(p - 1.0), c.y);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 pixelPos = input.uv * resolution;

    // Collect active trail points sorted by time
    // (we'll iterate all pairs anyway)
    float3 col = float3(0.0, 0.0, 0.0);
    float totalA = 0.0;

    for (uint i = 0; i < MAX_PARTICLES; i++) {
        Particle p = particlesRead[i];
        if (p.life >= 1.0) continue;

        float age = time - p.heat;
        if (age < 0.0 || age > 1.5) continue;

        float dist = length(pixelPos - p.pos);
        if (dist > 60.0) continue;

        // Age-based fade
        float fade = 1.0 - age / 1.5;
        fade = fade * fade;

        // Thickness based on speed at recording
        float thickness = 2.0 + smoothstep(0.0, 500.0, p.size) * 4.0;

        // Multi-layer glow
        float core = exp(-dist * dist / (thickness * thickness));
        float inner = exp(-dist * dist / (thickness * thickness * 6.0));
        float outer = exp(-dist * dist / (thickness * thickness * 20.0));

        float glow = core * 1.0 + inner * 0.4 + outer * 0.15;
        glow *= fade;

        // Rainbow color based on recording time
        float hue = frac(p.heat * 0.3);  // slow color cycling
        float3 trailCol = hsv2rgb(float3(hue, 0.8, 1.0));

        // White core
        float3 finalCol = lerp(trailCol, float3(1.0, 1.0, 1.0), core * 0.6);

        col += finalCol * glow;
        totalA += glow * 0.5;
    }

    totalA = saturate(totalA);
    if (totalA < 0.001) return float4(0.0, 0.0, 0.0, 0.0);

    return AT_PostProcess(col, totalA * 0.6);
}
