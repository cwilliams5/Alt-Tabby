// Water Surface — Crystal clear water viewed from above, cursor creates waves (compute + pixel)
// 2D wave equation on a height field grid. Cursor pushes the surface down,
// creating ripples that propagate, interfere, and reflect off boundaries.
// Nearly invisible when calm — waves visible through specular highlights and Fresnel.

static const float3 lightDir = float3(0.2591958, -0.4319929, 0.8639858);  // normalize(0.3,-0.5,1.0)


struct Cell {
    float2 _pad0;     // offset 0-7
    float height;     // wave displacement from rest (0 = calm)
    float velocity;   // rate of height change
    float _init;      // offset 16 (unused for water — rest state is zero)
    float _pad1;
    float _pad2;
    uint _pad3;
};

// ========================= COMPUTE SHADER =========================

RWStructuredBuffer<Cell> grid : register(u0);

int2 idxToGrid(uint idx) { return int2(idx % gridW, idx / gridW); }
uint gridToIdx(int2 g) {
    g = clamp(g, int2(0, 0), int2(gridW - 1, gridH - 1));
    return (uint)g.y * gridW + (uint)g.x;
}

float hash2(float2 p) {
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

[numthreads(64, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID) {
    uint idx = dtid.x;
    if (idx >= (gridW * gridH)) return;

    int2 g = idxToGrid(idx);
    Cell c = grid[idx];

    float2 cellUV = (float2(g) + 0.5) / float2((float)gridW, (float)gridH);
    float2 cellPos = cellUV * resolution;

    // --- MOUSE FORCE: directional bow wave + wake ---
    float2 fromMouse = cellPos - iMouse;
    float dist = length(fromMouse);
    float pushRadius = min(60.0 + iMouseSpeed * 0.2, 120.0);

    if (dist < pushRadius && iMouseSpeed > 5.0) {
        float falloff = 1.0 - dist / pushRadius;
        falloff *= falloff;
        float pushStrength = smoothstep(5.0, 300.0, iMouseSpeed) * 5.0 * reactivity;

        // Directional: bow wave ahead, trough behind
        float2 pushDir = iMouseVel / max(iMouseSpeed, 1.0);
        float ahead = (dist > 1.0) ? dot(normalize(fromMouse), pushDir) : 0.0;
        c.velocity += falloff * pushStrength * ahead * timeDelta;

        // Small omnidirectional depression (subtle, for some radial ripple)
        c.height -= falloff * pushStrength * 0.15 * timeDelta;
    }

    // --- 2D WAVE EQUATION ---
    float hL = grid[gridToIdx(g + int2(-1, 0))].height;
    float hR = grid[gridToIdx(g + int2(1, 0))].height;
    float hU = grid[gridToIdx(g + int2(0, -1))].height;
    float hD = grid[gridToIdx(g + int2(0, 1))].height;

    float laplacian = hL + hR + hU + hD - 4.0 * c.height;

    // Propagation: 0.25 gives slower waves that don't cross the full screen
    c.velocity += 0.25 * laplacian;
    c.height += c.velocity;

    // Damping: waves gradually lose energy
    c.velocity *= 0.98;
    c.height *= 0.995;  // waves die quickly

    // Clamp to prevent blowup
    c.height = clamp(c.height, -2.0, 2.0);
    c.velocity = clamp(c.velocity, -1.0, 1.0);

    grid[idx] = c;
}

// ========================= PIXEL SHADER =========================

StructuredBuffer<Cell> gridRead : register(t4);

uint gridToIdxPS(int2 g) {
    g = clamp(g, int2(0, 0), int2(gridW - 1, gridH - 1));
    return (uint)g.y * gridW + (uint)g.x;
}

float sampleHeight(float2 uv) {
    float2 gp = uv * float2((float)gridW, (float)gridH) - 0.5;
    int2 g = int2(floor(gp));
    float2 f = frac(gp);
    g = clamp(g, int2(0, 0), int2(gridW - 2, gridH - 2));
    float h00 = gridRead[gridToIdxPS(g)].height;
    float h10 = gridRead[gridToIdxPS(g + int2(1, 0))].height;
    float h01 = gridRead[gridToIdxPS(g + int2(0, 1))].height;
    float h11 = gridRead[gridToIdxPS(g + int2(1, 1))].height;
    return lerp(lerp(h00, h10, f.x), lerp(h01, h11, f.x), f.y);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 uv = input.uv;

    float height = sampleHeight(uv);

    // Normal from screen-space derivatives of height field
    float dhx = ddx(height);
    float dhy = ddy(height);
    float3 normal = normalize(float3(-dhx * 60.0, -dhy * 60.0, 1.0));

    // Lighting
    float3 viewDir = float3(0.0, 0.0, 1.0);
    float3 halfVec = normalize(lightDir + viewDir);

    // Specular — bright highlights where waves catch the light
    float spec = pow(max(dot(normal, halfVec), 0.0), 64.0);

    // Fresnel — wave edges are more visible (glancing angle reflection)
    float f = 1.0 - max(dot(normal, viewDir), 0.0);
    float fresnel = f * f * f;

    // Disturbance — how much the surface deviates from flat
    float gradient = length(float2(dhx, dhy));
    float disturbance = abs(height) * 2.0 + gradient * 20.0;

    // Intensity from all contributions
    float intensity = disturbance * 0.4 + spec + fresnel * 0.2;

    // Color ramp: subtle blue at low intensity → white at high (like light on crests)
    float3 col = lerp(
        float3(0.3, 0.5, 0.8),    // cool blue for gentle waves
        float3(0.9, 0.95, 1.0),   // white for bright crests
        saturate(intensity * 0.6)
    ) * intensity;

    // Specular stays pure white on top
    col += float3(0.9, 0.95, 1.0) * spec * 1.5;

    float alpha = saturate(intensity);

    if (alpha < 0.003) return float4(0.0, 0.0, 0.0, 0.0);

    return AT_PostProcess(col, alpha);
}
