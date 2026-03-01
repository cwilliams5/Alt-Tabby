// CC0: Spirals for windows terminal
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

static const float PI = 3.141592654;
static const float TAU = 2.0 * PI;

// GLSL mod: x - y * floor(x/y)
float glsl_mod(float x, float y) { return x - y * floor(x / y); }

// Rotation helper: returns float2(cos(a)*v.x - sin(a)*v.y, sin(a)*v.x + cos(a)*v.y)
float2 rot2(float2 v, float a) {
    float c = cos(a);
    float s = sin(a);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

float3 sRGB(float3 t) {
    return lerp(1.055 * pow(t, (float3)(1.0 / 2.4)) - 0.055, 12.92 * t, step(t, (float3)0.0031308));
}

float3 aces_approx(float3 v) {
    v = max(v, 0.0);
    v *= 0.6;
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((v * (a * v + b)) / (v * (c * v + d) + e), 0.0, 1.0);
}

float hash_val(float co) {
    return frac(sin(co * 12.9898) * 13758.5453);
}

float mod1(inout float p, float size) {
    float halfsize = size * 0.5;
    float c = floor((p + halfsize) / size);
    p = glsl_mod(p + halfsize, size) - halfsize;
    return c;
}

float2 rayCylinder(float3 ro, float3 rd, float3 cb, float3 ca, float cr) {
    float3 oc = ro - cb;
    float card = dot(ca, rd);
    float caoc = dot(ca, oc);
    float a = 1.0 - card * card;
    float b = dot(oc, rd) - caoc * card;
    float c = dot(oc, oc) - caoc * caoc - cr * cr;
    float h = b * b - a * c;
    if (h < 0.0) return float2(-1.0, -1.0);
    h = sqrt(h);
    return float2(-b - h, -b + h) / a;
}

float3 skyColor(float3 ro, float3 rd) {
    float3 l = normalize(float3(0.0, 0.0, -1.0));
    float3 baseCol = 0.005 * float3(0.05, 0.33, 1.0);
    return baseCol / (1.00025 + dot(rd, l));
}

float3 color_val(float3 ww, float3 uu, float3 vv, float3 ro, float2 p) {
    float rdd = 2.0;
    float mm = 3.0;
    float rep = 27.0;

    float3 rd = normalize(-p.x * uu + p.y * vv + rdd * ww);

    float3 skyCol = skyColor(ro, rd);

    float2 etc = rayCylinder(ro, rd, ro, float3(0.0, 0.0, 1.0), 1.0);
    float3 etcp = ro + rd * etc.y;
    // rd.yx *= ROT(0.3*etcp.z) — rotate (rd.y, rd.x)
    float2 rd_yx = rot2(float2(rd.y, rd.x), 0.3 * etcp.z);
    rd.y = rd_yx.x;
    rd.x = rd_yx.y;

    float3 col = skyCol;

    float a = atan2(rd.y, rd.x);
    for (float i = 0.0; i < mm; ++i) {
        float ma = a;
        float sz = rep + i * 6.0;
        float slices = TAU / sz;
        float na = mod1(ma, slices);

        float h1 = hash_val(na + 13.0 * i + 123.4);
        float h2 = frac(h1 * 3677.0);
        float h3 = frac(h1 * 8677.0);

        float tr = lerp(0.5, 3.0, h1);
        float2 tc = rayCylinder(ro, rd, ro, float3(0.0, 0.0, 1.0), tr);
        float3 tcp = ro + tc.y * rd;
        float2 tcp2 = float2(tcp.z, atan2(tcp.y, tcp.x));

        float zz = lerp(0.025, 0.05, sqrt(h1)) * rep / sz;
        float tnpy = mod1(tcp2.y, slices);
        float fo = smoothstep(0.5 * slices, 0.25 * slices, abs(tcp2.y));
        tcp2.x += -h2 * time;
        tcp2.y *= tr * PI / 3.0;
        float w = lerp(0.2, 1.0, h2);

        tcp2 /= zz;
        float d = abs(tcp2.y);
        d *= zz;

        float3 bcol = (1.0 + cos(float3(0.0, 1.0, 2.0) + TAU * h3 + 0.5 * h2 * h2 * tcp.z)) * 0.00005;
        bcol /= max(d * d, 5E-7 * tc.y * tc.y);
        bcol *= exp(-0.04 * tc.y * tc.y);
        bcol *= smoothstep(-0.5, 1.0, sin(lerp(0.125, 1.0, h2) * tcp.z));
        bcol *= fo;
        col += bcol;
    }

    return col;
}

float3 effect(float2 p, float2 pp) {
    float tm = time;
    float3 ro = float3(0.0, 0.0, tm);
    float3 dro = normalize(float3(1.0, 0.0, 3.0));
    // dro.xz *= ROT(0.2*sin(0.05*tm))
    float2 dro_xz = rot2(float2(dro.x, dro.z), 0.2 * sin(0.05 * tm));
    dro.x = dro_xz.x;
    dro.z = dro_xz.y;
    // dro.yz *= ROT(0.2*sin(0.05*tm*sqrt(0.5)))
    float2 dro_yz = rot2(float2(dro.y, dro.z), 0.2 * sin(0.05 * tm * sqrt(0.5)));
    dro.y = dro_yz.x;
    dro.z = dro_yz.y;
    float3 up = float3(0.0, 1.0, 0.0);
    float3 ww = normalize(dro);
    float3 uu = normalize(cross(up, ww));
    float3 vv = cross(ww, uu);
    float3 col = color_val(ww, uu, vv, ro, p);
    col -= 0.125 * float3(1.0, 2.0, 0.0) * length(pp);
    col = aces_approx(col);
    col = sRGB(col);
    return col;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 q = fragCoord / resolution.xy;
    float2 p = -1.0 + 2.0 * q;
    float2 pp = p;
    p.x *= resolution.x / resolution.y;

    float3 col = effect(p, pp);

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness + premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
