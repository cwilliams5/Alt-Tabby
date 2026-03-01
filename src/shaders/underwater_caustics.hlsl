cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

#define tau 6.28318530718

float sin01(float x) {
    return (sin(x * tau) + 1.0) / 2.0;
}

float cos01(float x) {
    return (cos(x * tau) + 1.0) / 2.0;
}

float2 rand01(float2 p) {
    float3 a = frac(p.xyx * float3(123.5, 234.34, 345.65));
    a += dot(a, a + 34.45);
    return frac(float2(a.x * a.y, a.y * a.z));
}

float circ(float2 uv, float2 pos, float r) {
    return smoothstep(r, 0.0, length(uv - pos));
}

float smoothFract(float x, float blurLevel) {
    return pow(cos01(x), 1.0 / blurLevel);
}

float manDist(float2 f, float2 t) {
    return abs(f.x - t.x) + abs(f.y - t.y);
}

float distFn(float2 f, float2 t) {
    float x = length(f - t);
    return pow(x, 4.0);
}

float voronoi(float2 uv, float t, float seed, float size) {
    float minDist = 100.0;
    float gridSize = size;

    float2 cellUv = frac(uv * gridSize) - 0.5;
    float2 cellCoord = floor(uv * gridSize);

    for (float x = -1.0; x <= 1.0; x += 1.0) {
        for (float y = -1.0; y <= 1.0; y += 1.0) {
            float2 cellOffset = float2(x, y);

            // Random 0-1 for each cell
            float2 rand01Cell = rand01(cellOffset + cellCoord + seed);

            // Get position of point
            float2 point = cellOffset + sin(rand01Cell * (t + 10.0)) * 0.5;

            // Get distance between pixel and point
            float dist = distFn(cellUv, point);
            minDist = min(minDist, dist);
        }
    }

    return minDist;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    // Center coordinates at 0
    float2 uv = (2.0 * fragCoord - resolution.xy) / resolution.y;

    float t = time * 0.35;

    // Distort uv coordinates
    float amplitude = 0.12;
    float turbulence = 0.5;
    uv.xy += sin01(uv.x * turbulence + t) * amplitude;
    uv.xy -= sin01(uv.y * turbulence + t) * amplitude;

    // Apply two layers of voronoi, one smaller
    float v = 0.0;
    float sizeDistortion = abs(uv.x) / 3.0;
    v += voronoi(uv, t * 2.0, 0.5, 2.5 - sizeDistortion);
    v += voronoi(uv, t * 4.0, 0.0, 4.0 - sizeDistortion) / 2.0;

    // Foreground color
    float3 col = v * float3(0.55, 0.75, 1.0);

    // Background color
    col += (1.0 - v) * float3(0.0, 0.3, 0.5);

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
