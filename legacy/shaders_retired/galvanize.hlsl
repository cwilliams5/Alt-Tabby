// Galvanize / Alcatraz
// Jochen 'Virgill' Feldkoetter
// Intro for Nordlicht demoparty 2014 - Shadertoy version
// https://www.shadertoy.com/view/4tc3zf

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

// globals
static int efx = 0;
static int refleco = 0;
static int snowo = 0;
static float4 orbitTrap = float4(0.0, 0.0, 0.0, 0.0);
static float blend_g = 0.0;
static float d_g = 0.0;
static float m_g = 0.0;
static float kalitime = 0.0;
static float depth_g = 0.0;
static float prec = 0.0;
static const float scene = 35.0;
static float2 g_fragCoord;

// Rotate
float3 rotXaxis(float3 p, float rad)
{
    float z2 = cos(rad) * p.z - sin(rad) * p.y;
    float y2 = sin(rad) * p.z + cos(rad) * p.y;
    p.z = z2;
    p.y = y2;
    return p;
}

float3 rotYaxis(float3 p, float rad)
{
    float x2 = cos(rad) * p.x - sin(rad) * p.z;
    float z2 = sin(rad) * p.x + cos(rad) * p.z;
    p.x = x2;
    p.z = z2;
    return p;
}

float3 rotZaxis(float3 p, float rad)
{
    float x2 = cos(rad) * p.x - sin(rad) * p.y;
    float y2 = sin(rad) * p.x + cos(rad) * p.y;
    p.x = x2;
    p.y = y2;
    return p;
}

// noise functions
float rand1(float2 co)
{
    return frac(sin(dot(co.xy, float2(12.9898, 78.233))) * 43758.5453);
}

float rand2(float2 co)
{
    return frac(cos(dot(co.xy, float2(12.9898, 78.233))) * 43758.5453);
}

// polynomial smooth min (IQ)
float sminPoly(float a, float b, float k)
{
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

// exponential smooth min (IQ)
float smin_f(float a, float b, float k)
{
    float res = exp(-k * a) + exp(-k * b);
    return -log(res) / k;
}

// length squared
float length2(float2 p)
{
    return dot(p, p);
}

// worley effect
float worley(float2 p)
{
    float d = 1.0;
    for (int xo = -1; xo <= 1; ++xo)
    for (int yo = -1; yo <= 1; ++yo)
    {
        float2 tp = floor(p) + float2(xo, yo);
        d = min(d, length2(p - tp - float2(rand1(tp), rand1(tp))));
    }
    return 3.0 * exp(-4.0 * abs(2.0 * d - 1.0));
}

float fworley(float2 p)
{
    return sqrt(sqrt(sqrt(worley(p * 32.0 + 4.3 + time * 0.250) * sqrt(worley(p * 64.0 + 5.3 + time * -0.125)) * sqrt(sqrt(worley(p * -128.0 + 7.3))))));
}

// menger
float NewMenger(float3 z)
{
    float Scale = 3.0;
    float3 Offset = float3(1.0, 1.0, 1.0);
    int Iterations = 6;
    int ColorIterations = 3;

    for (int n = 0; n < 6; n++)
    {
        z.z *= 1.0 + 0.2 * sin(time / 4.0) + 0.1;
        z = abs(z);
        if (z.x < z.y) { float tmp = z.x; z.x = z.y; z.y = tmp; }
        if (z.x < z.z) { float tmp = z.x; z.x = z.z; z.z = tmp; }
        if (z.y < z.z) { float tmp = z.y; z.y = z.z; z.z = tmp; }
        z = Scale * z - Offset * (Scale - 1.0);
        if (z.z < -0.5 * Offset.z * (Scale - 1.0)) z.z += Offset.z * (Scale - 1.0);

        if (n < ColorIterations) orbitTrap = min(orbitTrap, float4(abs(z), dot(z, z)));
    }
    return abs(length(z)) * pow(Scale, (float)(-Iterations - 1));
}

// mandelbulb (Fractalforums.com)
float Mandelbulb(float3 p)
{
    float Scale = 3.0;
    int Iterations = 6;
    int ColorIterations = 1;
    float parachute = (1.0 - min(1.8 * abs(sin((time - 5.0) * 3.1415 / scene)), 1.0));
    parachute = smoothstep(0.0, 1.0, parachute) * 35.0;
    float3 w = p;
    float dr = 1.0 + parachute;
    float r = 0.0;
    for (int i = 0; i < 6; ++i)
    {
        r = length(w);
        if (r > 4.0) break;
        dr *= pow(r, 7.0) * 8.0 + 1.0;
        float x = w.x; float x2 = x * x; float x4 = x2 * x2;
        float y = w.y; float y2 = y * y; float y4 = y2 * y2;
        float z = w.z; float z2 = z * z; float z4 = z2 * z2;
        float k3 = x2 + z2;
        float k2 = rsqrt(pow(k3, 7.0));
        float k1 = x4 + y4 + z4 - 6.0 * y2 * z2 - 6.0 * x2 * y2 + 2.0 * z2 * x2;
        float k4 = x2 - y2 + z2;
        w = float3(64.0 * x * y * z * (x2 - z2) * k4 * (x4 - 6.0 * x2 * z2 + z4) * k1 * k2, -16.0 * y2 * k3 * k4 * k4 + k1 * k1, -8.0 * y * k4 * (x4 * x4 - 28.0 * x4 * x2 * z2 + 70.0 * x4 * z4 - 28.0 * x2 * z2 * z4 + z4 * z4) * k1 * k2);
        w -= p;
        w = rotYaxis(w, sin(time * 0.14));
        w = rotZaxis(w, cos(time * 0.2));
        orbitTrap = min(orbitTrap, abs(float4(p.x * w.z, p.y * w.x, 0.0, 0.0)));
        if (i >= ColorIterations + 2) orbitTrap = float4(0.0, 0.0, 0.0, 0.0);
    }
    return 0.5 * log(r) * r / dr;
}

// kalibox (Kali / Fractalforums.com)
float Kalibox(float3 pos)
{
    float Scale = 1.84;
    int Iterations = 14;
    int ColorIterations = 3;
    float MinRad2 = 0.34;
    float3 Trans = float3(0.076, -1.86, 0.036);
    float3 Julia = float3(-0.66, -1.2 + (kalitime / 80.0), -0.66);
    float4 scale = float4(Scale, Scale, Scale, abs(Scale)) / MinRad2;
    float absScalem1 = abs(Scale - 1.0);
    float AbsScaleRaisedTo1mIters = pow(abs(Scale), (float)(1 - Iterations));
    float4 p = float4(pos, 1), p0 = float4(Julia, 1);
    for (int i = 0; i < 14; i++)
    {
        p.xyz = abs(p.xyz) + Trans;
        float r2 = dot(p.xyz, p.xyz);
        p *= clamp(max(MinRad2 / r2, MinRad2), 0.0, 1.0);
        p = p * scale + p0;
        if (i < ColorIterations) orbitTrap = min(orbitTrap, abs(float4(p.xyz, r2)));
    }
    return ((length(p.xyz) - absScalem1) / p.w - AbsScaleRaisedTo1mIters);
}

// balls and cube
float Balls(float3 pos)
{
    m_g = length(max(abs(rotYaxis(rotXaxis(pos + float3(0.0, -0.3, 0.0), time), time * 0.3)) - float3(0.35, 0.35, 0.35), 0.0)) - 0.02;
    m_g = smin_f(m_g, length(pos + float3(0.0, -0.40, 1.2 + 0.5 * sin(0.8 * time + 0.0))) - 0.4, 7.4);
    m_g = smin_f(m_g, length(pos + float3(0.0, -0.40, -1.2 - 0.5 * sin(0.8 * time + 0.4))) - 0.4, 7.4);
    m_g = smin_f(m_g, length(pos + float3(-1.2 - 0.5 * sin(0.8 * time + 0.8), -0.40, 0.0)) - 0.4, 7.4);
    m_g = smin_f(m_g, length(pos + float3(1.2 + 0.5 * sin(0.8 * time + 1.2), -0.40, 0.0)) - 0.4, 7.4);
    m_g = smin_f(m_g, length(pos + float3(0.0, -1.6 + 0.5 * -sin(0.8 * time + 1.6), 0.0)) - 0.4, 7.4);
    orbitTrap = float4(length(pos) - 0.8 * pos.z, length(pos) - 0.8 * pos.y, length(pos) - 0.8 * pos.x, 0.0) * 1.0;
    return m_g;
}

// plane
float sdPlane(float3 p)
{
    return p.y + (0.025 * sin(p.x * 10.0 + 1.4 * time)) + (0.025 * sin(p.z * 12.3 * cos(0.4 - p.x) + 1.6 * time)) - 0.05;
}

// cylinder
float sdCylinder(float3 p, float3 c)
{
    return length(p.xz - c.xy) - c.z;
}

// scene
float map(float3 p)
{
    orbitTrap = float4(10.0, 10.0, 10.0, 10.0);
    d_g = sdPlane(p);

    if (efx == 0) {
        m_g = Balls(p);
    }
    if (efx == 1) {
        m_g = NewMenger(rotYaxis(rotXaxis(p - float3(0.0, sin(time / 0.63) + 0.2, 0.0), 0.15 * time), 0.24 * time));
    }
    if (efx == 2) {
        m_g = Mandelbulb(rotYaxis(rotXaxis(p, time * 0.1), 0.21 * time));
    }
    if (efx == 3) {
        m_g = Kalibox(rotYaxis(rotXaxis(p, 1.50), 0.1 * time));
    }
    if (efx == 4 || efx == 5) {
        float3 c = float3(2.0, 8.0, 2.0);
        // GLSL mod: x - y*floor(x/y), always positive for positive y
        float3 poff = p - float3(1.0, 0.1 * time, 1.0);
        float3 q = poff - c * floor(poff / c) - 0.5 * c;
        float kali = Kalibox(rotYaxis(q, 0.04 * time));
        m_g = max(kali, -sdCylinder(p, float3(0.0, 0.0, 0.30 + 0.1 * sin(time * 0.2))));
    }
    d_g = sminPoly(m_g, d_g, 0.04);
    return d_g;
}

// normal calculation
float3 calcNormal(float3 p)
{
    float3 e = float3(0.001, 0.0, 0.0);
    float3 nor = float3(map(p + e.xyy) - map(p - e.xyy), map(p + e.yxy) - map(p - e.yxy), map(p + e.yyx) - map(p - e.yyx));
    return normalize(nor);
}

// cast
float castRay(float3 ro, float3 rd, float maxt)
{
    float precis = prec;
    float h = precis * 2.0;
    float t = depth_g;

    for (int i = 0; i < 122; i++)
    {
        if (abs(h) < precis || t > maxt) break;
        orbitTrap = float4(10.0, 10.0, 10.0, 10.0);
        h = map(ro + rd * t);
        t += h;
    }
    return t;
}

// softshadow (IQ)
float softshadow(float3 ro, float3 rd, float mint, float maxt, float k)
{
    float sh = 1.0;
    float t = mint;
    float h = 0.0;
    for (int i = 0; i < 19; i++)
    {
        if (t > maxt) continue;
        orbitTrap = float4(10.0, 10.0, 10.0, 10.0);
        h = map(ro + rd * t);
        sh = min(sh, k * h / t);
        t += h;
    }
    return sh;
}

// orbit color
static const float3 BaseColor = float3(0.2, 0.2, 0.2);
static const float3 OrbitStrength = float3(0.8, 0.8, 0.8);
static const float4 X_c = float4(0.5, 0.6, 0.6, 0.2);
static const float4 Y_c = float4(1.0, 0.5, 0.1, 0.7);
static const float4 Z_c = float4(0.8, 0.7, 1.0, 0.3);
static const float4 R_c = float4(0.7, 0.7, 0.5, 0.1);

float3 getColor()
{
    orbitTrap.w = sqrt(orbitTrap.w);
    float3 orbitColor = X_c.xyz * X_c.w * orbitTrap.x + Y_c.xyz * Y_c.w * orbitTrap.y + Z_c.xyz * Z_c.w * orbitTrap.z + R_c.xyz * R_c.w * orbitTrap.w;
    float3 color = lerp(BaseColor, 3.0 * orbitColor, OrbitStrength);
    return color;
}

// particles (Andrew Baldwin)
float snow(float3 direction)
{
    float help = 0.0;
    // mat3 p in GLSL is column-major; mul() in HLSL with float3x3 is row-major
    // GLSL mat3(a,b,c, d,e,f, g,h,i) fills columns: col0=(a,b,c), col1=(d,e,f), col2=(g,h,i)
    // HLSL float3x3(a,b,c, d,e,f, g,h,i) fills rows: row0=(a,b,c), row1=(d,e,f), row2=(g,h,i)
    // Since we use p*m (GLSL) = mul(m, p) with transposed matrix, we transpose:
    static const float3x3 pm = float3x3(
        13.323122, 21.1212, 21.8112,
        23.5112,   28.7312, 14.7212,
        21.71123,  11.9312, 61.3934);
    float2 uvx = float2(direction.x, direction.z) + float2(1.0, resolution.y / resolution.x) * g_fragCoord.xy / resolution.xy;
    float acc = 0.0;
    float DEPTH = direction.y * direction.y - 0.3;
    float WIDTH = 0.1;
    float SPEED = 0.1;
    for (int i = 0; i < 10; i++)
    {
        float fi = (float)i;
        float2 q = uvx * (1.0 + fi * DEPTH);
        q += float2(q.y * (WIDTH * frac(fi * 7.238917) - WIDTH * 0.5), SPEED * time / (1.0 + fi * DEPTH * 0.03));
        float3 n = float3(floor(q), 31.189 + fi);
        float3 fm = floor(n) * 0.00001 + frac(n);
        float3 mp = (31415.9 + fm) / frac(mul(pm, fm));
        float3 r = frac(mp);
        float2 qmod = q - floor(q); // GLSL mod(q, 1.0)
        float2 s = abs(qmod - 0.5 + 0.9 * r.xy - 0.45);
        float dd = 0.7 * max(s.x - s.y, s.x + s.y) + max(s.x, s.y) - 0.01;
        float edge = 0.04;
        acc += smoothstep(edge, -edge, dd) * (r.x / 1.0);
        help = acc;
    }
    return help;
}

// GLSL mod equivalent (always positive)
float glmod(float x, float y) { return x - y * floor(x / y); }

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    g_fragCoord = fragCoord;

    if (time >= 0.0  && time <= 35.0)  { efx = 4; refleco = 0; snowo = 0; }
    if (time > 35.0  && time <= 70.0)  { efx = 0; refleco = 1; snowo = 1; }
    if (time > 70.0  && time <= 105.0) { efx = 1; refleco = 0; snowo = 1; }
    if (time > 105.0 && time <= 140.0) { efx = 3; refleco = 0; snowo = 1; }
    if (time > 140.0 && time <= 175.0) { efx = 2; refleco = 0; snowo = 1; }
    if (time > 175.0 && time <= 210.0) { efx = 4; refleco = 0; snowo = 0; }
    if (time > 210.0 && time <= 245.0) { efx = 5; refleco = 0; snowo = 0; }

    blend_g = max(min(2.0 * abs(sin((time + 0.0) * 3.1415 / scene)), 1.0), 0.3);
    float2 uv = fragCoord.xy / resolution.xy;
    float2 p = uv * 2.0 - 1.0;
    p.x *= resolution.x / resolution.y;
    float theta = sin(time * 0.03) * 3.14 * 2.0;
    float x = 3.0 * cos(theta) + 0.007 * rand1(fragCoord.xy);
    float z = 3.0 * sin(theta) + 0.007 * rand2(fragCoord.xy);
    float3 ro = (float3)0;

    if (efx == 0) {
        prec = 0.001;
        ro = float3(x * 0.2 + 1.0, 5.0, z * 2.0 - 3.0);
    }
    if (efx == 1) {
        prec = 0.002;
        ro = float3(x * 1.2, 7.0, z * 2.0);
    }
    if (efx == 2) {
        prec = 0.002;
        ro = float3(x * 1.0, 6.2, z * 2.8);
        depth_g = 4.0;
    }
    if (efx == 3) {
        kalitime = 40.0;
        prec = 0.002;
        ro = float3(x * 1.7, 2.6, 2.0);
    }
    if (efx == 4) {
        prec = 0.002;
        kalitime = time - 15.0;
        ro = float3(0.0, 8.0, 0.0001);
    }
    if (efx == 5) {
        prec = 0.004;
        kalitime = 210.0 + 175.0;
        ro = float3(0, 3.8, 0.0001);
    }

    float3 ta = float3(0.0, 0.25, 0.0);
    float3 cw = normalize(ta - ro);
    float3 cp = float3(0.0, 1.0, 0.0);
    float3 cu = normalize(cross(cw, cp));
    float3 cv = normalize(cross(cu, cw));
    float3 rd = normalize(p.x * cu + p.y * cv + 7.5 * cw);

    // render
    float3 col = float3(0.0, 0.0, 0.0);
    float t = castRay(ro, rd, 12.0);
    float3 pos = ro + rd * t;
    float3 nor = calcNormal(pos);
    float3 lig;
    if (efx == 4 || efx == 5)   lig = normalize(float3(-0.4 * sin(time * 0.15), 1.0, 0.5));
    else if (efx == 3)          lig = normalize(float3(-0.1 * sin(time * 0.2), 0.2, 0.4 * sin(time * 0.1)));
    else                        lig = normalize(float3(-0.4, 0.7, 0.5));
    float dif = clamp(dot(lig, nor), 0.0, 1.0);
    float spec = pow(clamp(dot(reflect(rd, nor), lig), 0.0, 1.0), 16.0);
    float sh = 1.0;
    if (efx == 1 || efx == 5) sh = softshadow(pos, lig, 0.02, 20.0, 7.0);
    float3 color = getColor();
    col = ((0.8 * dif + spec) + 0.35 * color);
    if (efx != 1 && efx != 5) sh = softshadow(pos, lig, 0.02, 20.0, 7.0);
    col = col * clamp(sh, 0.0, 1.0);

    // reflections
    if (refleco == 1) {
        float3 col2 = float3(0.0, 0.0, 0.0);
        float3 ro2 = pos - rd / t;
        float3 rd2 = reflect(rd, nor);
        float t2 = castRay(ro2, rd2, 7.0);
        float3 pos2 = float3(0.0, 0.0, 0.0);
        if (t2 < 7.0) {
            pos2 = ro2 + rd2 * t2;
        }
        float3 nor2 = calcNormal(pos2);
        float dif2 = clamp(dot(lig, nor2), 0.0, 1.0);
        float spec2 = pow(clamp(dot(reflect(rd2, nor2), lig), 0.0, 1.0), 16.0);
        col += 0.22 * float3(dif2 * color + (float3)spec2);
    }

    // postprocessing
    float klang1 = 0.75;
    float2 uv2 = -0.3 + 2.0 * fragCoord.xy / resolution.xy;
    col -= 0.20 * (1.0 - klang1) * rand1(uv2.xy * time);
    col *= 0.9 + 0.20 * (1.0 - klang1) * sin(10.0 * time + uv2.x * resolution.x);
    col *= 0.9 + 0.20 * (1.0 - klang1) * sin(10.0 * time + uv2.y * resolution.y);
    float Scr = 1.0 - dot(uv2, uv2) * 0.15;
    float2 uv3 = fragCoord.xy / resolution.xy;
    float worl = fworley(uv3 * resolution.xy / 2100.0);
    worl *= exp(-length2(abs(2.0 * uv3 - 1.0)));
    worl *= abs(1.0 - 0.6 * dot(2.0 * uv3 - 1.0, 2.0 * uv3 - 1.0));
    if (efx == 4) col += float3(0.4 * worl, 0.35 * worl, 0.25 * worl);
    if (efx == 5) col += float3(0.2 * worl, 0.2 * worl, 0.2 * worl);
    float g2 = (blend_g / 2.0) + 0.39;
    float g1 = ((1.0 - blend_g) / 2.0);
    if (uv3.y >= g2 + 0.11) col *= 0.0;
    if (uv3.y >= g2 + 0.09) col *= 0.4;
    if (uv3.y >= g2 + 0.07) { if (glmod(uv3.x - 0.06 * time, 0.18) <= 0.16) col *= 0.5; }
    if (uv3.y >= g2 + 0.05) { if (glmod(uv3.x - 0.04 * time, 0.12) <= 0.10) col *= 0.6; }
    if (uv3.y >= g2 + 0.03) { if (glmod(uv3.x - 0.02 * time, 0.08) <= 0.06) col *= 0.7; }
    if (uv3.y >= g2 + 0.01) { if (glmod(uv3.x - 0.01 * time, 0.04) <= 0.02) col *= 0.8; }
    if (uv3.y <= g1 + 0.10) { if (glmod(uv3.x + 0.01 * time, 0.04) <= 0.02) col *= 0.8; }
    if (uv3.y <= g1 + 0.08) { if (glmod(uv3.x + 0.02 * time, 0.08) <= 0.06) col *= 0.7; }
    if (uv3.y <= g1 + 0.06) { if (glmod(uv3.x + 0.04 * time, 0.12) <= 0.10) col *= 0.6; }
    if (uv3.y <= g1 + 0.04) { if (glmod(uv3.x + 0.06 * time, 0.18) <= 0.16) col *= 0.5; }
    if (uv3.y <= g1 + 0.02) col *= 0.4;
    if (uv3.y <= g1 + 0.00) col *= 0.0;

    float4 fragColor;
    if (snowo == 1) fragColor = (float4(col * 1.0 * Scr - 1.6 * snow(cv), 1.0) * blend_g) * float4(1.0, 0.93, 1.0, 1.0);
    else fragColor = float4(col * 1.0 * Scr, 1.0) * blend_g;

    float3 finalCol = fragColor.rgb;

    // darken/desaturate
    float lum = dot(finalCol, float3(0.299, 0.587, 0.114));
    finalCol = lerp(finalCol, float3(lum, lum, lum), desaturate);
    finalCol = finalCol * (1.0 - darken);

    // alpha from brightness, premultiply
    float a = max(finalCol.r, max(finalCol.g, finalCol.b));
    return float4(finalCol * a, a);
}
