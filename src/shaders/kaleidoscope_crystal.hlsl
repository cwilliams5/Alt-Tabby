#define DTR 0.01745329

// GLSL mat2 is column-major, HLSL float2x2 is row-major — transpose elements
float2x2 rot(float a) {
    float s, c;
    sincos(a, s, c);
    return float2x2(c, -s, s, c);
}

static float2 g_uv;
static float3 cp, cn, cr, ro, rd, ss, oc, cc, gl, vb;
static float4 fc;
static float tt, cd, sd, io, oa, td;
static int es = 0, ec;

// Hoisted loop-invariant rotation matrices (set in PSMain, used in mp/lattice)
static float2x2 _rotTT;      // rot(tt * 0.1)
static float2x2 _latRotPos;  // rot(latAn * DTR)
static float2x2 _latRotNeg;  // rot(-latAn * DTR)

float bx(float3 p, float3 s) {
    float3 q = abs(p) - s;
    return min(max(q.x, max(q.y, q.z)), 0.0) + length(max(q, (float3)0));
}

float smin_f(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

float3 lattice(float3 p, int iter) {
    for (int i = 0; i < iter; i++) {
        p.xy = mul(_latRotPos, p.xy);
        p.yz = abs(p.yz) - 1.0;
        p.xz = mul(_latRotNeg, p.xz);
    }
    return p;
}

float mp(float3 p) {
    // Mouse control removed — no mouse in Alt-Tabby

    p.xz = mul(_rotTT, p.xz);
    p.xy = mul(_rotTT, p.xy);

    p = lattice(p, 9);

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
    float3 rd_off = abs(rd + float3(0.0, 0.5, 0.0));
    cc = float3(0.35, 0.25, 0.45) + length(rd_off * rd_off * rd_off) * 0.3 + gl; // pow(x,3)
    float3 l = float3(0.9, 0.7, 0.5);
    if (cd > 128.0) { oa = 1.0; return; }
    float df = saturate(length(cn * l));
    float oneMinusDf = 1.0 - df;
    float3 fr = (oneMinusDf * oneMinusDf * oneMinusDf) * lerp(cc, (float3)0.4, 0.5);
    float sp = (1.0 - length(cross(cr, cn * l))) * 0.2;
    float ao = min(mp(cp + cn * 0.3) - 0.3, 0.3) * 0.4;
    cc = lerp((oc * (df + fr + ss) + fr + sp + ao + gl), oc, vb.x);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    tt = fmod(time + 25.0, 260.0);
    // Hoist loop-invariant rotations: tt is constant across all march iterations
    _rotTT = rot(tt * 0.1);
    float _latAn = 45.0 + cos(tt * 0.1) * 5.0;
    _latRotPos = rot(_latAn * DTR);
    _latRotNeg = rot(-_latAn * DTR);
    g_uv = float2(fragCoord.x / resolution.x, fragCoord.y / resolution.y);
    g_uv -= 0.5;
    g_uv /= float2(resolution.y / resolution.x, 1.0);
    float an = (sin(tt * 0.3) * 0.5 + 0.5);
    float _an2 = an*an; float _an4 = _an2*_an2; float _an5 = an*_an4;
    float _b = 1.0 - _an5; float _b2 = _b*_b; float _b4 = _b2*_b2; float _b8 = _b4*_b4;
    an = 1.0 - _b2*_b8;
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
        if (dot(cr, cr) == 0.0 && es <= 0) { cr = reflect(rd, cn); es = ec; }
        if (max(es, 0) % 3 == 0 && cd < 128.0) rd = cr;
        es--;
        if (vb.x > 0.0 && i % 2 == 1) oa = pow(saturate(cd / vb.y), vb.z);
        px();
        fc = fc + float4(cc * oa, oa) * (1.0 - fc.a);
        if (fc.a >= 1.0 || cd > 128.0) break;
    }

    float3 color = (fc / fc.a).rgb;

    return AT_PostProcess(color);
}
