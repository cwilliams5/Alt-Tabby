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

static float det = 0.001, t, boxhit;
static float3 adv, boxp;
static float2 gFragCoord;

float2 glsl_mod(float2 x, float2 y) { return x - y * floor(x / y); }
float glsl_mod(float x, float y) { return x - y * floor(x / y); }

float hash(float2 p) {
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float2x2 rot(float a) {
    float s = sin(a), c = cos(a);
    return float2x2(c, s, -s, c);
}

float3 path(float t) {
    float3 p = float3(float2(sin(t * 0.1), cos(t * 0.05)) * 10.0, t);
    p.x += smoothstep(0.0, 0.5, abs(0.5 - frac(t * 0.02))) * 10.0;
    return p;
}

float fractal(float2 p) {
    p = abs(5.0 - glsl_mod(p * 0.2, (float2)10.0)) - 5.0;
    float ot = 1000.0;
    for (int i = 0; i < 7; i++) {
        p = abs(p) / clamp(p.x * p.y, 0.25, 2.0) - 1.0;
        if (i > 0)
            ot = min(ot, abs(p.x) + 0.7 * frac(abs(p.y) * 0.05 + t * 0.05 + (float)i * 0.3));
    }
    ot = exp(-10.0 * ot);
    return ot;
}

float box(float3 p, float3 l) {
    float3 c = abs(p) - l;
    return length(max((float3)0, c)) + min(0.0, max(c.x, max(c.y, c.z)));
}

float de(float3 p) {
    boxhit = 0.0;
    float3 p2 = p - adv;
    p2.xz = mul(rot(t * 0.2), p2.xz);
    p2.xy = mul(rot(t * 0.1), p2.xy);
    p2.yz = mul(rot(t * 0.15), p2.yz);
    float b = box(p2, (float3)1.0);
    p.xy -= path(p.z).xy;
    float s = sign(p.y);
    p.y = -abs(p.y) - 3.0;
    p.z = glsl_mod(p.z, 20.0) - 10.0;
    for (int i = 0; i < 5; i++) {
        p = abs(p) - 1.0;
        p.xz = mul(rot(radians(s * -45.0)), p.xz);
        p.yz = mul(rot(radians(90.0)), p.yz);
    }
    float f = -box(p, float3(5.0, 5.0, 10.0));
    float d = min(f, b);
    if (d == b) {
        boxp = p2;
        boxhit = 1.0;
    }
    return d * 0.7;
}

float3 march(float3 from, float3 dir) {
    float3 p;
    float3 g = (float3)0;
    float d, td = 0.0;
    for (int i = 0; i < 80; i++) {
        p = from + td * dir;
        d = de(p) * (1.0 - hash(gFragCoord + t) * 0.3);
        if (d < det && boxhit < 0.5) break;
        td += max(det, abs(d));
        float f = fractal(p.xy) + fractal(p.xz) + fractal(p.yz);
        float b = fractal(boxp.xy) + fractal(boxp.xz) + fractal(boxp.yz);
        float3 colf = float3(f * f, f, f * f * f);
        float3 colb = float3(b + 0.1, b * b + 0.05, 0.0);
        g += colf / (3.0 + d * d * 2.0) * exp(-0.0015 * td * td) * step(5.0, td) / 2.0 * (1.0 - boxhit);
        g += colb / (10.0 + d * d * 20.0) * boxhit * 0.5;
    }
    return g;
}

float3x3 lookat(float3 d, float3 up) {
    d = normalize(d);
    float3 rt = normalize(cross(d, normalize(up)));
    return float3x3(rt, cross(rt, d), d);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    gFragCoord = fragCoord;
    float2 uv = (fragCoord - resolution * 0.5) / resolution.y;
    t = time * 7.0;
    float3 from = path(t);
    adv = path(t + 6.0 + sin(t * 0.1) * 3.0);
    float3 dir = normalize(float3(uv, 0.7));
    dir = mul(dir, lookat(adv - from, float3(0.0, 1.0, 0.0)));
    float3 col = march(from, dir);

    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
