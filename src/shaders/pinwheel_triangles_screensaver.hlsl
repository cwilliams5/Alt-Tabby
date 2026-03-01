// Pinwheel Triangles ScreenSaver - Conway pinwheel tiling
// Original: https://www.shadertoy.com/view/XsSfWm by ttoinou

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

#define SHOW_SEGMENTS 1

// segment.x is distance to closest point
// segment.y is barycentric coefficient for closest point
// segment.z is length of closest point on curve, starting from A
// segment.w is approximate length of curve
float4 segmentDist(float2 p, float2 a, float2 b) {
    a -= p;
    b -= p;
    float3 k = float3(dot(a, a), dot(b, b), dot(a, b));
    float t = (k.x - k.z) / (k.x + k.y - 2.0 * k.z);
    float len = length(b - a);

    if (t < 0.0) {
        return float4(sqrt(k.x), 0.0, 0.0, len);
    } else if (t > 1.0) {
        return float4(sqrt(k.y), 1.0, len, len);
    } else {
        return float4(length(a * (1.0 - t) + b * t), t, t * len, len);
    }
}

#define HASHSCALE3 float3(.1031, .1030, .0973)

float3 hash32(float2 p) {
    float3 p3 = frac(p.xyx * HASHSCALE3);
    p3 += dot(p3, p3.yxz + 19.19);
    return frac((p3.xxy + p3.yzz) * p3.zyx);
}

float3 mixColorLine(float2 uv, float3 currentCol, float3 colLine, float2 lineA, float2 lineB, float scale) {
    return lerp(
        currentCol,
        colLine,
        1.0 - smoothstep(0.0, 1.0, sqrt(segmentDist(uv, lineA, lineB).x * scale)));

}

bool pointsOnSameSideOfLine(float2 pointA, float2 pointB, float2 lineA, float2 lineB) {
    float2 n = lineB - lineA;
    n = float2(n.y, -n.x);
    return dot(pointA - lineA, n) * dot(pointB - lineA, n) > 0.0;
}

static float viewportMagnify = 1.0;

float2 screenToViewport(float2 uv) {
    return (uv - resolution.xy / 2.0) / min(resolution.x, resolution.y) * viewportMagnify;
}

float det22(float2 a, float2 b) {
    return a.x * b.y - a.y * b.x;
}

struct Pinwheel {
    float2 A;
    float2 B;
    float2 C;
    float2 D;
    float2 E;
    float2 F;
    float2 G;
};

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float4 fragColor = (float4)1.0;

    int nbIterations = 5;

    float2 base = float2(2.0, 1.0);

    float2 uv = screenToViewport(fragCoord.xy);

    viewportMagnify = 1.0 / 3.2;
    uv *= viewportMagnify;

    // Rotation matrix from cos(t + offsets)
    float4 cv = cos(time / 48.0 + float4(0.0, 1.6, -1.6, 0.0));
    float2x2 rotMat = float2x2(cv.x, cv.y, cv.z, cv.w);
    uv = mul(uv, rotMat);

    uv += base / 3.2;

    // Base Triangle
    Pinwheel Tri;
    Pinwheel Tri_TMP;
    Tri.A = Tri.B = Tri.C = (float2)0.0;
    Tri.D = Tri.E = Tri.F = Tri.G = (float2)0.0;
    Tri_TMP.A = Tri_TMP.B = Tri_TMP.C = (float2)0.0;
    Tri_TMP.D = Tri_TMP.E = Tri_TMP.F = Tri_TMP.G = (float2)0.0;
    Tri.B.x += base.x;
    Tri.C.y += base.y;
    int PinwheelID = 0;

    for (int i = 0; i < 5; i++) {
        PinwheelID *= 5;
        // EQUERRE_COMPUTE_DEFG
        Tri.E = (Tri.A + Tri.B) / 2.0;
        Tri.F = (3.0 * Tri.B + 2.0 * Tri.C) / 5.0;
        Tri.G = (Tri.B + 4.0 * Tri.C) / 5.0;
        Tri.D = (Tri.G + Tri.A) / 2.0;

        if (pointsOnSameSideOfLine(uv, Tri.F, Tri.E, Tri.G)) {
            if (pointsOnSameSideOfLine(uv, Tri.B, Tri.E, Tri.F)) {
                // GET1
                Tri_TMP.A = Tri.F;
                Tri_TMP.B = Tri.B;
                Tri_TMP.C = Tri.E;
            } else {
                // GET2
                Tri_TMP.A = Tri.F;
                Tri_TMP.B = Tri.G;
                Tri_TMP.C = Tri.E;
                PinwheelID += 1;
            }
        } else if (pointsOnSameSideOfLine(uv, Tri.E, Tri.A, Tri.G)) {
            if (pointsOnSameSideOfLine(uv, Tri.G, Tri.E, Tri.D)) {
                // GET3
                Tri_TMP.A = Tri.D;
                Tri_TMP.B = Tri.E;
                Tri_TMP.C = Tri.G;
                PinwheelID += 2;
            } else {
                // GET4
                Tri_TMP.A = Tri.D;
                Tri_TMP.B = Tri.E;
                Tri_TMP.C = Tri.A;
                PinwheelID += 3;
            }
        } else {
            // GET5
            Tri_TMP.A = Tri.G;
            Tri_TMP.B = Tri.A;
            Tri_TMP.C = Tri.C;
            PinwheelID += 4;
        }

        // EQUERRE_COPY
        Tri.A = Tri_TMP.A;
        Tri.B = Tri_TMP.B;
        Tri.C = Tri_TMP.C;
    }

    float3 v = cos(
        time / float3(63.0, 54.0, 69.0) / float(nbIterations) / 1.2
        + float3(0.0, 0.95, 1.22))
        * float3(36.0, 34.0, 31.0)
        + float3(25.0, 19.0, 42.0);

    // Time-based color shift (replaces iMouse.xy interaction)
    float3 s = float3(
        sin(time / 3.0) * 0.5 + 0.5,
        sin(time * 0.071) * 0.5 + 0.5,
        cos(time * 0.113) * 0.5 + 0.5);

    fragColor.rgb = fmod((float3)PinwheelID, v) / (v - 1.0);
    fragColor.rgb = fmod(fragColor.rgb + s, (float3)1.0);

    float scale = float(nbIterations);
    scale = pow(2.0, scale) / viewportMagnify / scale * 5.5;

    float3 EquerreColor = (float3)0.0;

    #if SHOW_SEGMENTS==1
        fragColor.rgb = mixColorLine(uv, fragColor.rgb, EquerreColor, Tri.A, Tri.B, scale);
        fragColor.rgb = mixColorLine(uv, fragColor.rgb, EquerreColor, Tri.B, Tri.C, scale);
        fragColor.rgb = mixColorLine(uv, fragColor.rgb, EquerreColor, Tri.C, Tri.A, scale);
    #endif

    fragColor.rgb = tanh(fragColor.rgb * 6.0);

    // Darken/desaturate post-processing
    float3 col = fragColor.rgb;
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
