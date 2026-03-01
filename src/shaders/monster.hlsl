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

static const float TK = 1.0;
static const float PI = 3.1415926535;

float2 rot(float2 p, float r) {
    float2x2 m = float2x2(cos(r), sin(r), -sin(r), cos(r));
    return mul(p, m);
}

float2 pmod(float2 p, float n) {
    float np = 2.0 * PI / n;
    float r = atan2(p.x, p.y) - 0.5 * np;
    r = fmod(r, np) - 0.5 * np;
    return length(p) * float2(cos(r), sin(r));
}

float cube(float3 p, float3 s) {
    float3 q = abs(p);
    float3 m = max(s - q, 0.0);
    return length(max(q - s, 0.0)) - min(min(m.x, m.y), m.z);
}

float dist(float3 p) {
    p.z -= 1.0 * TK * time;
    p.xy = rot(p.xy, 1.0 * p.z);
    p.xy = pmod(p.xy, 6.0);
    float k = 0.7;
    float zid = floor(p.z * k);
    p = fmod(p, k) - 0.5 * k;
    for (int i = 0; i < 4; i++) {
        p = abs(p) - 0.3;

        p.xy = rot(p.xy, 1.0 + zid + 0.1 * TK * time);
        p.xz = rot(p.xz, 1.0 + 4.7 * zid + 0.3 * TK * time);
    }
    return min(cube(p, float3(0.3, 0.3, 0.3)), length(p) - 0.4);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 uv = fragCoord / resolution.xy;
    uv = 2.0 * (uv - 0.5);
    uv.y *= resolution.y / resolution.x;
    uv = rot(uv, TK * time);
    float3 ro = float3(0.0, 0.0, 0.1);
    float3 rd = normalize(float3(uv, 0.0) - ro);
    float t = 2.0;
    float d = 0.0;
    float ac = 0.0;
    for (int i = 0; i < 66; i++) {
        d = dist(ro + rd * t) * 0.2;
        d = max(0.0, abs(d));
        t += d;
        if (d < 0.001) ac += 0.1;
    }
    float3 col = float3(0.0, 0.0, 0.0);
    col = float3(0.1, 0.7, 0.7) * 0.2 * float3(ac, ac, ac);
    float3 pn = ro + rd * t;
    float kn = 0.5;
    pn.z += -1.5 * time * TK;
    pn.z = fmod(pn.z, kn) - 0.5 * kn;
    float em = clamp(0.01 / pn.z, 0.0, 100.0);
    col += 3.0 * em * float3(0.1, 1.0, 0.1);
    col = clamp(col, 0.0, 1.0);

    // Apply darken/desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
