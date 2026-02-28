// Glittery
// Based on https://www.shadertoy.com/view/lslyRn
//          https://www.shadertoy.com/view/lscczl
// License: CC BY-NC-SA 3.0

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

#define iterations 17
#define formuparam 0.53

#define volsteps 20
#define stepsize 0.1

#define zoom   0.800
#define tile   0.850

#define brightness 0.0015
#define darkmatter 0.300
#define distfading 0.730
#define saturation 0.850
#define S(a, b, val) smoothstep(a, b, val)

static const float pi = 3.14159265359;
static const float triangleScale = 0.816497161855865;
static const float3 orange = float3(0.937, 0.435, 0.0);

float3 glsl_mod(float3 x, float3 y) { return x - y * floor(x / y); }

float rand(float2 co) {
    return frac(sin(dot(co, float2(12.9898, 78.233))) * 43758.5453);
}

// --- Triangle grid functions ---

float4 getTriangleCoords(float2 uv) {
    uv.y /= triangleScale;
    uv.x -= uv.y / 2.0;
    float2 center = floor(uv);
    float2 local = frac(uv);

    center.x += center.y / 2.0;
    center.y *= triangleScale;

    if (local.x + local.y > 1.0) {
        local.x -= 1.0 - local.y;
        local.y = 1.0 - local.y;
        center.y += 0.586;
        center.x += 1.0;
    } else {
        center.y += 0.287;
        center.x += 0.5;
    }

    return float4(center, local);
}

float4 getLoader(float4 tri) {
    if (length(tri.xy) > 1.6) {
        return (float4)0;
    }

    float angle = atan2(tri.x, tri.y);
    float seed = rand(tri.xy);
    float dst = min(tri.z, min(tri.w, 1.0 - tri.z - tri.w)) * 15.0;
    float glow = dst < pi ? pow(sin(dst), 1.5) : 0.0;

    return float4(lerp(orange, (float3)1.0, glow * 0.07), pow(0.5 + 0.5 * sin(angle - time * 6.0 + seed), 2.0));
}

float getBackground(float4 tri) {
    float dst = min(tri.z, min(tri.w, 1.0 - tri.z - tri.w)) - 0.05;

    if (tri.y > 1.9 || tri.y < -2.4 || dst < 0.0) {
        return 0.0;
    }

    float value = pow(0.5 + 0.5 * cos(-abs(tri.x) * 0.4 + rand(tri.xy) * 2.0 + time * 4.0), 2.0) * 0.08;
    return value * (dst > 0.05 ? 0.65 : 1.0);
}

float3 getColor(float2 uv) {
    uv *= 2.0 / resolution.y;

    float3 background = (float3)getBackground(getTriangleCoords(uv * 6.0 - float2(0.5, 0.3)));
    float4 loader = getLoader(getTriangleCoords(uv * 11.0));

    float3 color = lerp(background, loader.rgb, loader.a);
    return color;
}

// --- Line/triangle synapse network ---
// Note: GLSL 'line' and 'triangle' renamed to avoid HLSL reserved keywords

float N21(float2 p) {
    p = frac(p * float2(233.34, 851.73));
    p += dot(p, p + 23.45);
    return frac(p.x * p.y);
}

float2 N22(float2 p) {
    float n = N21(p);
    return float2(n, N21(p + n));
}

float2 getPos(float2 id, float2 offset) {
    float2 n = N22(id + offset) * time;
    return offset + sin(n) * 0.4;
}

float distLine(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float t = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * t);
}

float lineSeg(float2 p, float2 a, float2 b) {
    float d = distLine(p, a, b);
    float m = S(0.03, 0.01, d);
    float d2 = length(a - b);
    m *= S(1.2, 0.8, d2) * 0.5 + S(0.05, 0.03, abs(d2 - 0.75));
    return m;
}

float distTriangle(float2 p, float2 p0, float2 p1, float2 p2) {
    float2 e0 = p1 - p0;
    float2 e1 = p2 - p1;
    float2 e2 = p0 - p2;

    float2 v0 = p - p0;
    float2 v1 = p - p1;
    float2 v2 = p - p2;

    float2 pq0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0, 1.0);
    float2 pq1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0, 1.0);
    float2 pq2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0, 1.0);

    float s = sign(e0.x * e2.y - e0.y * e2.x);
    float2 d = min(min(float2(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x)),
                       float2(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x))),
                   float2(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x)));

    return -sqrt(d.x) * sign(d.y);
}

float triSeg(float2 p, float2 a, float2 b, float2 c) {
    float d = distTriangle(p, a, b, c);
    float m = S(0.03, 0.01, d);
    float d2 = length(a - b);
    m *= S(1.2, 0.8, d2) * 0.5 + S(0.05, 0.03, abs(d2 - 0.75));
    return m;
}

float layer(float2 uv) {
    float2 gv = frac(uv) - 0.5;
    float2 id = floor(uv);

    float2 p[9];
    int idx = 0;
    for (float y = -1.0; y <= 1.0; y++) {
        for (float x = -1.0; x <= 1.0; x++) {
            p[idx++] = getPos(id, float2(x, y));
        }
    }

    float t = time * 10.0;
    float m = 0.0;
    for (int i = 0; i < 9; i++) {
        m += lineSeg(gv, p[4], p[i]);

        float2 j = (p[i] - gv) * 20.0;
        float sparkle = 1.0 / dot(j, j);
        m += sparkle * (sin(t + frac(p[i].x) * 10.0) * 0.5 + 0.5);

        for (int yi = i + 1; yi < 9; yi++) {
            for (int zi = yi + 1; zi < 9; zi++) {
                float len1 = abs(length(p[i] - p[yi]));
                float len2 = abs(length(p[yi] - p[zi]));
                float len3 = abs(length(p[i] - p[zi]));
                if ((len1 + len2 + len3) < 2.8) {
                    m += triSeg(gv, p[i], p[yi], p[zi]) * 0.8;
                }
            }
        }
    }

    m += lineSeg(gv, p[1], p[3]);
    m += lineSeg(gv, p[1], p[5]);
    m += lineSeg(gv, p[7], p[3]);
    m += lineSeg(gv, p[7], p[5]);

    return m;
}

// --- Volumetric star field ---

float4 volumetric(float3 ro, float3 rd) {
    float s = 0.1, fade = 1.0;
    float3 v = (float3)0;
    for (int r = 0; r < volsteps; r++) {
        float3 p = ro + s * rd * 0.5;
        p = abs((float3)tile - glsl_mod(p, (float3)(tile * 2.0)));
        float pa = 0.0, a = 0.0;
        for (int i = 0; i < iterations; i++) {
            p = abs(p) / dot(p, p) - formuparam;
            a += abs(length(p) - pa);
            pa = length(p);
        }
        float dm = max(0.0, darkmatter - a * a * 0.001);
        a *= a * a;
        if (r > 6) fade *= 1.1;
        v += fade;
        v += float3(s, s * s, s * s * s * s) * a * brightness * fade;
        fade *= distfading;
        s += stepsize;
    }
    v = lerp((float3)length(v), v, saturation);
    return float4(v * 0.03, 1.0);
}

// --- Entry point ---

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord / resolution.xy - 0.5;
    uv.y *= resolution.y / resolution.x;
    float3 dir = float3(uv * zoom, time * 0.002);

    // Line/triangle synapse network
    float m = 0.0;
    float t = time * 0.1;
    float gradient = uv.y;

    float sn = sin(t);
    float cs = cos(t);
    // GLSL column-major mat2(c,-s,s,c) -> HLSL row-major (transposed)
    float2x2 rot = float2x2(cs, sn, -sn, cs);
    uv = mul(uv, rot);

    for (float i = 0.0; i < 1.0; i += 1.0 / 4.0) {
        float z = frac(i + t);
        float sz = lerp(10.0, 0.5, z);
        float fade = S(0.0, 0.5, z) * S(1.0, 0.8, z);
        m += layer(uv * sz + i * 20.0) * fade;
    }

    float3 base = sin(t * 5.0 * float3(0.345, 0.456, 0.567)) * 0.4 + 0.6;
    float3 col = m * base;
    col -= gradient * base;

    // Triangle grid (supersampled, modulates star field camera)
    float2 fc = fragCoord - 0.5 * resolution;
    float3 triColor = 0.25 * (getColor(fc)
                              + getColor(fc + float2(0.5, 0.0))
                              + getColor(fc + float2(0.5, 0.5))
                              + getColor(fc + float2(0.0, 0.5)));

    // Volumetric star field (camera origin influenced by triangle grid)
    // speed=0.0 in original -> localTime=0.25 (constant)
    float3 from = float3(1.0, 0.5, 0.5) + triColor + float3(0.5, 0.25, -2.0);
    float4 vr = volumetric(from, dir);
    float3 color = vr.rgb * col;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float alpha = max(color.r, max(color.g, color.b));
    return float4(color * alpha, alpha);
}
