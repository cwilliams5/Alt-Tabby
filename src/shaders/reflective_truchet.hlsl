// Reflective truchet' — mrange
// https://www.shadertoy.com/view/w3GBD3
// License: CC0
// Reflective truchet torus tiles with colored lighting

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

float2x2 ROT(float a) {
    float c = cos(a), s = sin(a);
    return float2x2(c, s, -s, c);
}

static const float MaxDistance = 30.0;
static const float ColorOffset = 0.5;
// normalize(float3(1, 2, -1)) precomputed
static const float3 LD = float3(0.40824829, 0.81649658, -0.40824829);
static const float3 RO = float3(0, 0, -3);
static const float3 ColorBase = float3(0.5, 1.5, 2.5);

static float2x2 R0;
static float2x2 R1;

float length4(float2 p) {
    return sqrt(length(p * p));
}

float3 hash(float3 r) {
    float h = frac(sin(dot(r.xy, float2(1.38984 * sin(r.z), 1.13233 * cos(r.z)))) * 653758.5453);
    return frac(h * float3(1, 3667, 8667));
}

// License: MIT, author: Inigo Quilez
float torus(float3 p) {
    const float2 t = 0.5 * float2(1.0, 0.3);
    float2 q = float2(length(p.xz) - t.x, p.y);
    return length4(q) - t.y;
}

// License: MIT, author: Inigo Quilez
float pmin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

float pmax(float a, float b, float k) {
    return -pmin(-a, -b, k);
}

float df(float3 p) {
    float D, k, d, j;
    float3 P, h, n;

    D = length(p - RO) - 0.75;
    k = 4.0 / dot(p, p);
    p *= k;
    p.xz = mul(R0, p.xz);
    p.xy = mul(R1, p.xy);
    p.z -= 0.25 * time;
    d = 1e3;
    for (j = 0.0; j < 2.0; ++j) {
        P = p + j * 0.5;
        n = floor(P + 0.5);
        h = hash(n + 123.4);
        P -= n;
        P *= -1.0 + 2.0 * step(h, (float3)0.5);
        d = min(d, torus(P - float3(0.5, 0, 0.5)));
        d = min(d, torus(P.yzx + float3(0.5, 0, 0.5)));
        d = min(d, torus(P.yxz - float3(0.5, 0, -0.5)));
    }
    d /= k;
    d = pmax(d, -D, 0.5);

    return d;
}

float3 normal(float3 p) {
    float2 e = float2(1e-3, 0);
    return normalize(float3(
        df(p + e.xyy) - df(p - e.xyy),
        df(p + e.yxy) - df(p - e.yxy),
        df(p + e.yyx) - df(p - e.yyx)));
}

float march(float3 P, float3 I) {
    float i, d, z = 0.0, nz = 0.0, nd = 1e3;

    for (i = 0.0; i < 77.0; ++i) {
        d = df(z * I + P);
        if (d < 1e-3 || z > MaxDistance) break;
        if (d < nd) {
            nd = d;
            nz = z;
        }
        z += d;
    }

    if (i == 77.0) {
        z = nz;
    }

    return z;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float i, f, z, A = 1.0;
    float3 o = (float3)0, c, p, n, r;
    float3 P = RO;
    float3 I = normalize(float3(fragCoord - 0.5 * resolution, resolution.y));

    R0 = ROT(0.213 * 0.5 * time);
    R1 = ROT(0.123 * 0.5 * time);

    for (i = 0.0; i < 4.0 && A > 0.07; ++i) {
        c = (float3)0;
        z = march(P, I);
        p = z * I + P;
        n = normal(p);
        r = reflect(I, n);
        f = 1.0 + dot(n, I);
        f *= f;
        if (z < MaxDistance)
            c += pow(max(0.0, dot(n, LD)), 9.0);
        o += A * c * (1.1 + sin(2.5 * f + ColorBase));
        A *= lerp(0.3, 0.7, f);
        P = p + 0.05 * n;
        I = r;
    }

    o *= 3.0;
    o = sqrt(o) - 0.07;
    o = max(o, 0.0);

    float3 color = o;

    // Darken / desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
