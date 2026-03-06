// Fluid Calm — Container filled with smoke, only cursor disturbs it (compute + pixel)
// Same as Fluid Aquarium but without ambient turbulence. The fog sits perfectly
// still until the mouse moves through it. More meditative, minimal.

#define GRID_W 1024
#define GRID_H 512
#define TOTAL_CELLS 524288
#define MAX_PARTICLES TOTAL_CELLS

struct Cell {
    float2 vel;       // velocity field (px/sec)
    float density;    // smoke density (0=clear, ~0.8=rest)
    float pressure;   // scratch
    float _init;      // 1.0 on buffer creation, 0.0 after first-frame init
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

    // --- FIRST-FRAME INIT: fill container with smoke ---
    if (c._init > 0.5) {
        c.density = 0.8;
        c._init = 0.0;
    }

    float2 cellUV = (float2(g) + 0.5) / float2(GRID_W, GRID_H);
    float2 cellPos = cellUV * resolution;

    // --- MOUSE FORCE (velocity + direct density displacement) ---
    float2 fromMouse = cellPos - iMouse;
    float dist = length(fromMouse);
    float pushRadius = min(50.0 + iMouseSpeed * 0.2, 100.0);

    if (dist < pushRadius && iMouseSpeed > 5.0) {
        float falloff = 1.0 - dist / pushRadius;
        falloff *= falloff;
        float2 pushDir = iMouseVel / max(iMouseSpeed, 1.0);
        c.vel += pushDir * falloff * iMouseSpeed * 3.0 * timeDelta;
        if (dist > 1.0)
            c.vel += normalize(fromMouse) * falloff * iMouseSpeed * 2.0 * timeDelta;
    }

    // No ambient turbulence — fog is perfectly still until disturbed

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

    // --- VOID PUNCH (AFTER advection so it doesn't get overwritten) ---
    float voidRadius = min(52.0 + iMouseSpeed * 0.15, 90.0);
    if (dist < voidRadius && iMouseSpeed > 10.0) {
        float voidFalloff = 1.0 - dist / voidRadius;
        voidFalloff *= voidFalloff;
        float pushAmt = voidFalloff * smoothstep(10.0, 300.0, iMouseSpeed) * 18.0 * timeDelta;
        c.density = max(c.density - pushAmt, 0.0);
    }

    // --- RESTORE toward rest density (fills voids back in) ---
    c.density = lerp(c.density, 0.8, 0.1 * timeDelta);

    c.density = clamp(c.density, 0.0, 1.5);

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

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;

    float density = sampleDensity(uv);

    // Multi-octave detail noise to add sub-grid texture
    float2 detailUV = uv * resolution * 0.01 + float2(time * 0.15, time * 0.1);
    float detail = noise1(detailUV) * 0.1;
    float2 detailUV2 = uv * resolution * 0.025 + float2(time * -0.08, time * 0.12);
    detail += noise1(detailUV2) * 0.05;
    density = saturate(density + detail * density);

    // Fog color — density IS the visual (void = transparent, dense = opaque)
    float3 col = float3(0.6, 0.65, 0.75) * density;

    float alpha = density * 0.45;
    if (alpha < 0.005) return float4(0, 0, 0, 0);

    return AT_PostProcess(col, alpha);
}
