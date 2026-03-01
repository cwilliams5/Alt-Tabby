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

static const float pi = 3.14159265358979;
static const float pi2 = pi * 2.0;

float2x2 rot(float a) {
    float c = cos(a), s = sin(a);
    return float2x2(c, s, -s, c);
}

float2 pmod(float2 p, float r) {
    float a = atan2(p.x, p.y) + pi / r;
    float n = pi2 / r;
    a = floor(a / n) * n;
    return mul(p, rot(-a));
}

float box(float3 p, float3 b) {
    float3 d = abs(p) - b;
    return min(max(d.x, max(d.y, d.z)), 0.0) + length(max(d, 0.0));
}

float ifsBox(float3 p) {
    for (int i = 0; i < 5; i++) {
        p = abs(p) - 1.0;
        p.xy = mul(p.xy, rot(time * 0.3));
        p.xz = mul(p.xz, rot(time * 0.1));
    }
    p.xz = mul(p.xz, rot(time));
    return box(p, float3(0.4, 0.8, 0.3));
}

float map(float3 p, float3 cPos) {
    float3 p1 = p;
    p1.x = fmod(p1.x - 5.0, 10.0) - 5.0;
    p1.y = fmod(p1.y - 5.0, 10.0) - 5.0;
    p1.z = fmod(p1.z, 16.0) - 8.0;
    p1.xy = pmod(p1.xy, 5.0);
    return ifsBox(p1);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 p = (fragCoord.xy * 2.0 - resolution.xy) / min(resolution.x, resolution.y);

    float3 cPos = float3(0.0, 0.0, -3.0 * time);
    float3 cDir = normalize(float3(0.0, 0.0, -1.0));
    float3 cUp = float3(sin(time), 1.0, 0.0);
    float3 cSide = cross(cDir, cUp);

    float3 ray = normalize(cSide * p.x + cUp * p.y + cDir);

    // Phantom Mode
    float acc = 0.0;
    float acc2 = 0.0;
    float t = 0.0;
    for (int i = 0; i < 99; i++) {
        float3 pos = cPos + ray * t;
        float dist = map(pos, cPos);
        dist = max(abs(dist), 0.02);
        float a = exp(-dist * 3.0);
        if (fmod(length(pos) + 24.0 * time, 30.0) < 3.0) {
            a *= 2.0;
            acc2 += a;
        }
        acc += a;
        t += dist * 0.5;
    }

    float3 col = float3(acc * 0.01, acc * 0.011 + acc2 * 0.002, acc * 0.012 + acc2 * 0.005);

    // Apply darken/desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Shader provides its own alpha; premultiply
    float a2 = saturate(1.0 - t * 0.03);
    return float4(col * a2, a2);
}
