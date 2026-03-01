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

#define DTR 0.01745329

// GLSL mat2 is column-major, HLSL float2x2 is row-major — transpose elements
float2x2 rot(float a) {
    float c = cos(a), s = sin(a);
    return float2x2(c, -s, s, c);
}

static float2 g_uv;
static float3 cp, cn, cr, ro, rd, ss, oc, cc, gl, vb;
static float4 fc;
static float tt, cd, sd, io, oa, td;
static int es = 0, ec;

float bx(float3 p, float3 s) {
    float3 q = abs(p) - s;
    return min(max(q.x, max(q.y, q.z)), 0.0) + length(max(q, (float3)0));
}

float smin_f(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

float3 lattice(float3 p, int iter, float an) {
    for (int i = 0; i < iter; i++) {
        p.xy = mul(rot(an * DTR), p.xy);
        p.yz = abs(p.yz) - 1.0;
        p.xz = mul(rot(-an * DTR), p.xz);
    }
    return p;
}

float mp(float3 p) {
    // Mouse control removed — no mouse in Alt-Tabby

    p.xz = mul(rot(tt * 0.1), p.xz);
    p.xy = mul(rot(tt * 0.1), p.xy);

    p = lattice(p, 9, 45.0 + cos(tt * 0.1) * 5.0);

    sd = bx(p, (float3)1) - 0.01;

    sd = smin_f(sd, sd, 0.8);

    gl += exp(-sd * 0.001) * normalize(p * p) * 0.003;

    sd = abs(sd) - 0.001;

    if (sd < 0.001) {
        oc = (float3)1;
        io = 1.2;
        oa = 0.0;
        ss = (float3)0;
        vb = float3(0.0, 10.0, 2.8);
        ec = 2;
    }
    return sd;
}

void tr() {
    vb.x = 0.0;
    cd = 0.0;
    for (float i = 0.0; i < 256.0; i++) {
        mp(ro + rd * cd);
        cd += sd;
        td += sd;
        if (sd < 0.0001 || cd > 128.0) break;
    }
}

void nm() {
    float3 k0 = cp - float3(0.001, 0.0, 0.0);
    float3 k1 = cp - float3(0.0, 0.001, 0.0);
    float3 k2 = cp - float3(0.0, 0.0, 0.001);
    cn = normalize(mp(cp) - float3(mp(k0), mp(k1), mp(k2)));
}

void px() {
    cc = float3(0.35, 0.25, 0.45) + length(pow(abs(rd + float3(0.0, 0.5, 0.0)), (float3)3)) * 0.3 + gl;
    float3 l = float3(0.9, 0.7, 0.5);
    if (cd > 128.0) { oa = 1.0; return; }
    float df = clamp(length(cn * l), 0.0, 1.0);
    float3 fr = pow(1.0 - df, 3.0) * lerp(cc, (float3)0.4, 0.5);
    float sp = (1.0 - length(cross(cr, cn * l))) * 0.2;
    float ao = min(mp(cp + cn * 0.3) - 0.3, 0.3) * 0.4;
    cc = lerp((oc * (df + fr + ss) + fr + sp + ao + gl), oc, vb.x);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    tt = fmod(time + 25.0, 260.0);
    g_uv = float2(fragCoord.x / resolution.x, fragCoord.y / resolution.y);
    g_uv -= 0.5;
    g_uv /= float2(resolution.y / resolution.x, 1.0);
    float an = (sin(tt * 0.3) * 0.5 + 0.5);
    an = 1.0 - pow(1.0 - pow(an, 5.0), 10.0);
    ro = float3(0.0, 0.0, -5.0 - an * 15.0);
    rd = normalize(float3(g_uv, 1.0));

    // Reset per-pixel state
    gl = (float3)0;
    fc = (float4)0;
    td = 0.0;
    es = 0;

    for (int i = 0; i < 25; i++) {
        tr();
        cp = ro + rd * cd;
        nm();
        ro = cp - cn * 0.01;
        cr = refract(rd, cn, i % 2 == 0 ? 1.0 / io : io);
        if (length(cr) == 0.0 && es <= 0) { cr = reflect(rd, cn); es = ec; }
        if (max(es, 0) % 3 == 0 && cd < 128.0) rd = cr;
        es--;
        if (vb.x > 0.0 && i % 2 == 1) oa = pow(clamp(cd / vb.y, 0.0, 1.0), vb.z);
        px();
        fc = fc + float4(cc * oa, oa) * (1.0 - fc.a);
        if (fc.a >= 1.0 || cd > 128.0) break;
    }

    float3 color = (fc / fc.a).rgb;

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
