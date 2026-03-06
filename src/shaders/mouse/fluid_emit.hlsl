// Fluid Emit — Smoke emitted from cursor with real fluid dynamics (compute + pixel)
// Cursor leaves trails of smoke that flow, swirl, and rise with natural buoyancy.
// 128x64 velocity+density grid with semi-Lagrangian advection.

#define GRID_W 256
#define GRID_H 128
#define TOTAL_CELLS 32768
#define MAX_PARTICLES TOTAL_CELLS

struct Cell {
    float2 vel;       // velocity field (px/sec)
    float density;    // smoke density (0=clear, 1+=full)
    float pressure;   // scratch
    float _init;      // buffer creation marker (unused here)
    float _pad1;
    float _pad2;
    uint _pad3;
};

// ========================= COMPUTE SHADER =========================

RWStructuredBuffer<Cell> grid : register(u0);

int2 idxToGrid(uint idx) { return int2(idx % GRID_W, idx / GRID_W); }
uint gridToIdx(int2 g) {
    g = clamp(g, int2(0, 0), int2(GRID_W - 1, GRID_H - 1));
    return (uint)g.y * GRID_W + (uint)g.x;
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

float sampleField(float2 uv) {
    uv = clamp(uv, float2(0.002, 0.002), float2(0.998, 0.998));
    float2 gp = uv * float2(GRID_W, GRID_H) - 0.5;
    int2 g = int2(floor(gp));
    float2 f = frac(gp);
    g = clamp(g, int2(0, 0), int2(GRID_W - 2, GRID_H - 2));
    float d00 = grid[gridToIdx(g)].density;
    float d10 = grid[gridToIdx(g + int2(1, 0))].density;
    float d01 = grid[gridToIdx(g + int2(0, 1))].density;
    float d11 = grid[gridToIdx(g + int2(1, 1))].density;
    return lerp(lerp(d00, d10, f.x), lerp(d01, d11, f.x), f.y);
}

[numthreads(64, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID) {
    uint idx = dtid.x;
    if (idx >= TOTAL_CELLS) return;

    int2 g = idxToGrid(idx);
    Cell c = grid[idx];

    float2 cellUV = (float2(g) + 0.5) / float2(GRID_W, GRID_H);
    float2 cellPos = cellUV * resolution;

    // --- MOUSE FORCE ---
    float2 fromMouse = cellPos - iMouse;
    float dist = length(fromMouse);
    float pushRadius = 60.0 + iMouseSpeed * 0.4;

    if (dist < pushRadius && iMouseSpeed > 5.0) {
        float falloff = 1.0 - dist / pushRadius;
        falloff *= falloff;
        float2 pushDir = iMouseVel / max(iMouseSpeed, 1.0);
        c.vel += pushDir * falloff * iMouseSpeed * 0.5 * timeDelta;
        if (dist > 1.0)
            c.vel += normalize(fromMouse) * falloff * iMouseSpeed * 0.2 * timeDelta;
    }

    // --- BUOYANCY (smoke rises — negative Y = up in screen coords) ---
    c.vel.y -= c.density * 30.0 * timeDelta;

    // --- VELOCITY DIFFUSION ---
    float2 avgVel = float2(0, 0);
    int neighbors = 0;
    [unroll] for (int dy = -1; dy <= 1; dy++) {
        [unroll] for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            int2 ng = g + int2(dx, dy);
            if (ng.x >= 0 && ng.x < GRID_W && ng.y >= 0 && ng.y < GRID_H) {
                avgVel += grid[gridToIdx(ng)].vel;
                neighbors++;
            }
        }
    }
    if (neighbors > 0) {
        avgVel /= (float)neighbors;
        c.vel = lerp(c.vel, avgVel, 0.15 * saturate(timeDelta * 60.0));
    }

    // --- SEMI-LAGRANGIAN ADVECTION (density) ---
    float2 srcUV = cellUV - c.vel * timeDelta / resolution;
    c.density = sampleField(srcUV);

    // --- EMIT DENSITY at cursor ---
    float emitRadius = 25.0 + iMouseSpeed * 0.1;
    if (dist < emitRadius && iMouseSpeed > 10.0) {
        float emit = (1.0 - dist / emitRadius);
        emit *= smoothstep(10.0, 200.0, iMouseSpeed);
        c.density += emit * 3.0 * timeDelta;
    }

    // --- DISSIPATION ---
    c.density *= (1.0 - 0.4 * timeDelta);
    c.density = saturate(c.density);

    // --- VELOCITY DAMPING ---
    c.vel *= (1.0 - 1.5 * timeDelta);

    // --- BOUNDARY ---
    if (g.x == 0 || g.x == GRID_W - 1) c.vel.x *= 0.1;
    if (g.y == 0 || g.y == GRID_H - 1) c.vel.y *= 0.1;

    grid[idx] = c;
}

// ========================= PIXEL SHADER =========================

StructuredBuffer<Cell> gridRead : register(t4);

uint gridToIdxPS(int2 g) {
    g = clamp(g, int2(0, 0), int2(GRID_W - 1, GRID_H - 1));
    return (uint)g.y * GRID_W + (uint)g.x;
}

float sampleDensity(float2 uv) {
    float2 gp = uv * float2(GRID_W, GRID_H) - 0.5;
    int2 g = int2(floor(gp));
    float2 f = frac(gp);
    g = clamp(g, int2(0, 0), int2(GRID_W - 2, GRID_H - 2));
    float d00 = gridRead[gridToIdxPS(g)].density;
    float d10 = gridRead[gridToIdxPS(g + int2(1, 0))].density;
    float d01 = gridRead[gridToIdxPS(g + int2(0, 1))].density;
    float d11 = gridRead[gridToIdxPS(g + int2(1, 1))].density;
    return lerp(lerp(d00, d10, f.x), lerp(d01, d11, f.x), f.y);
}

float2 sampleVel(float2 uv) {
    float2 gp = uv * float2(GRID_W, GRID_H) - 0.5;
    int2 g = int2(floor(gp));
    float2 f = frac(gp);
    g = clamp(g, int2(0, 0), int2(GRID_W - 2, GRID_H - 2));
    float2 v00 = gridRead[gridToIdxPS(g)].vel;
    float2 v10 = gridRead[gridToIdxPS(g + int2(1, 0))].vel;
    float2 v01 = gridRead[gridToIdxPS(g + int2(0, 1))].vel;
    float2 v11 = gridRead[gridToIdxPS(g + int2(1, 1))].vel;
    return lerp(lerp(v00, v10, f.x), lerp(v01, v11, f.x), f.y);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;

    float density = sampleDensity(uv);
    if (density < 0.005) return float4(0, 0, 0, 0);

    float2 vel = sampleVel(uv);
    float speed = length(vel);

    // Detail noise to hide grid resolution
    float2 detailUV = uv * resolution * 0.008 + float2(time * 0.3, time * 0.2);
    float detail = noise1(detailUV) * 0.2;
    density = saturate(density + detail * density);

    // Warm smoke — brighter when flowing
    float3 col = lerp(
        float3(0.55, 0.55, 0.6),
        float3(0.75, 0.75, 0.85),
        smoothstep(0.0, 150.0, speed)
    ) * density;

    return AT_PostProcess(col, density * 0.7);
}
