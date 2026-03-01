// Galvanize Tunnel
// From Alcatraz 8K intro Galvanize
// Jochen 'Virgill' Feldkoetter
// https://www.shadertoy.com/view/MlX3Wr

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

// GLSL-compatible mod (handles negatives correctly)
float glsl_mod(float x, float y) { return x - y * floor(x / y); }
float2 glsl_mod(float2 x, float2 y) { return x - y * floor(x / y); }
float3 glsl_mod(float3 x, float3 y) { return x - y * floor(x / y); }

// Mutable globals (per-pixel in HLSL via static)
static float blend_g = 0.0;
static float scene = 35.0;
static float d_g = 0.0;
static float m_g = 0.0;
static float kalitime;
static float depth_g = 0.0;
static float prec_g = 0.002;
static float4 orbitTrap = (float4)0.0;

// Rotate
float3 rotXaxis(float3 p, float rad) {
    float z2 = cos(rad) * p.z - sin(rad) * p.y;
    float y2 = sin(rad) * p.z + cos(rad) * p.y;
    p.z = z2; p.y = y2;
    return p;
}

float3 rotYaxis(float3 p, float rad) {
    float x2 = cos(rad) * p.x - sin(rad) * p.z;
    float z2 = sin(rad) * p.x + cos(rad) * p.z;
    p.x = x2; p.z = z2;
    return p;
}

float3 rotZaxis(float3 p, float rad) {
    float x2 = cos(rad) * p.x - sin(rad) * p.y;
    float y2 = sin(rad) * p.x + cos(rad) * p.y;
    p.x = x2; p.y = y2;
    return p;
}

// Rand
float rand1(float2 co) {
    return frac(sin(dot(co.xy, float2(12.9898, 78.233))) * 43758.5453);
}

// Polynomial smooth min (IQ)
float sminPoly(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

// Length squared
float length2(float2 p) {
    return dot(p, p);
}

// Worley effect
float worley(float2 p) {
    float dw = 1.0;
    for (int xo = -1; xo <= 1; ++xo)
    for (int yo = -1; yo <= 1; ++yo) {
        float2 tp = floor(p) + float2((float)xo, (float)yo);
        dw = min(dw, length2(p - tp - float2(rand1(tp), rand1(tp))));
    }
    return 3.0 * exp(-4.0 * abs(2.0 * dw - 1.0));
}

float fworley(float2 p) {
    return sqrt(sqrt(sqrt(
        worley(p * 32.0 + 4.3 + time * 0.250) *
        sqrt(worley(p * 64.0 + 5.3 + time * -0.125)) *
        sqrt(sqrt(worley(p * -128.0 + 7.3)))));
}

// Kalibox (Kali / Fractalforums.com)
float Kalibox(float3 pos) {
    float Scale = 1.84;
    int ColorIterations = 3;
    float MinRad2 = 0.34;
    float3 Trans = float3(0.076, -1.86, 0.036);
    float3 Julia = float3(-0.66, -1.2 + (kalitime / 80.0), -0.66);
    float4 scale = float4(Scale, Scale, Scale, abs(Scale)) / MinRad2;
    float absScalem1 = abs(Scale - 1.0);
    float AbsScaleRaisedTo1mIters = pow(abs(Scale), (float)(1 - 14));
    float4 p = float4(pos, 1.0), p0 = float4(Julia, 1.0);
    for (int i = 0; i < 14; i++) {
        p.xyz = abs(p.xyz) + Trans;
        float r2 = dot(p.xyz, p.xyz);
        p *= clamp(max(MinRad2 / r2, MinRad2), 0.0, 1.0);
        p = p * scale + p0;
        if (i < ColorIterations) orbitTrap = min(orbitTrap, abs(float4(p.xyz, r2)));
    }
    return ((length(p.xyz) - absScalem1) / p.w - AbsScaleRaisedTo1mIters);
}

// Plane
float sdPlane(float3 p) {
    return p.y + (0.025 * sin(p.x * 10.0 + 1.4 * time)) + (0.025 * sin(p.z * 12.3 * cos(0.4 - p.x) + 1.6 * time)) - 0.05;
}

// Cylinder
float sdCylinder(float3 p, float3 c) {
    return length(p.xz - c.xy) - c.z;
}

// Map
float map(float3 p) {
    orbitTrap = (float4)10.0;
    d_g = sdPlane(p);

    float3 c = float3(2.0, 8.0, 2.0);
    float3 q = glsl_mod(p - float3(1.0, 0.1 * time, 1.0), c) - 0.5 * c;
    float kali = Kalibox(rotYaxis(q, 0.04 * time));
    m_g = max(kali, -sdCylinder(p, float3(0.0, 0.0, 0.30 + 0.1 * sin(time * 0.2))));

    d_g = sminPoly(m_g, d_g, 0.04);
    return d_g;
}

// Normal Calculation
float3 calcNormal(float3 p) {
    float3 e = float3(0.001, 0.0, 0.0);
    float3 nor = float3(
        map(p + e.xyy) - map(p - e.xyy),
        map(p + e.yxy) - map(p - e.yxy),
        map(p + e.yyx) - map(p - e.yyx));
    return normalize(nor);
}

// Cast
float castRay(float3 ro, float3 rd, float maxt) {
    float precis = prec_g;
    float h = precis * 2.0;
    float t = depth_g;

    for (int i = 0; i < 122; i++) {
        if (abs(h) < precis || t > maxt) break;
        orbitTrap = (float4)10.0;
        h = map(ro + rd * t);
        t += h;
    }
    return t;
}

// Softshadow (IQ)
float softshadow(float3 ro, float3 rd, float mint, float maxt, float k) {
    float sh = 1.0;
    float t = mint;
    float h = 0.0;
    for (int i = 0; i < 19; i++) {
        if (t > maxt) continue;
        orbitTrap = (float4)10.0;
        h = map(ro + rd * t);
        sh = min(sh, k * h / t);
        t += h;
    }
    return sh;
}

// Orbit color
float3 getColor() {
    float3 BaseColor = float3(0.2, 0.2, 0.2);
    float3 OrbitStrength = float3(0.8, 0.8, 0.8);
    float4 X = float4(0.5, 0.6, 0.6, 0.2);
    float4 Y = float4(1.0, 0.5, 0.1, 0.7);
    float4 Z = float4(0.8, 0.7, 1.0, 0.3);
    float4 R = float4(0.7, 0.7, 0.5, 0.1);
    orbitTrap.w = sqrt(orbitTrap.w);
    float3 orbitColor = X.xyz * X.w * orbitTrap.x + Y.xyz * Y.w * orbitTrap.y + Z.xyz * Z.w * orbitTrap.z + R.xyz * R.w * orbitTrap.w;
    float3 color = lerp(BaseColor, 3.0 * orbitColor, OrbitStrength);
    return color;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    kalitime = time - 15.0;
    blend_g = min(2.0 * abs(sin((time + 0.0) * 3.1415 / scene)), 1.0);
    float2 uv = fragCoord.xy / resolution.xy;
    float2 p = uv * 2.0 - 1.0;
    p.x *= resolution.x / resolution.y;
    float theta = sin(time * 0.03) * 3.14 * 2.0;
    float x = 3.0 * cos(theta);
    float z = 3.0 * sin(theta);
    float3 ro;

    ro = float3(0.0, 8.0, 0.0001);

    float3 ta = float3(0.0, 0.25, 0.0);
    float3 cw = normalize(ta - ro);
    float3 cp = float3(0.0, 1.0, 0.0);
    float3 cu = normalize(cross(cw, cp));
    float3 cv = normalize(cross(cu, cw));
    float3 rd = normalize(p.x * cu + p.y * cv + 7.5 * cw);

    // Render
    float3 col = (float3)0.0;
    float t = castRay(ro, rd, 12.0);
    float3 pos = ro + rd * t;
    float3 nor = calcNormal(pos);
    float3 lig;
    lig = normalize(float3(-0.4 * sin(time * 0.15), 1.0, 0.5));

    float dif = clamp(dot(lig, nor), 0.0, 1.0);
    float spec = pow(clamp(dot(reflect(rd, nor), lig), 0.0, 1.0), 16.0);
    float sh = softshadow(pos, lig, 0.02, 20.0, 7.0);
    float3 color = getColor();
    col = ((0.8 * dif + spec) + 0.35 * color);
    col = col * clamp(sh, 0.0, 1.0);

    // Postprocessing
    float klang1 = 0.4;
    float2 uv2 = -0.3 + 2.0 * fragCoord.xy / resolution.xy;
    col -= 0.20 * (1.0 - klang1) * rand1(uv2.xy * time);
    col *= 0.9 + 0.20 * (1.0 - klang1) * sin(10.0 * time + uv2.x * resolution.x);
    col *= 0.9 + 0.20 * (1.0 - klang1) * sin(10.0 * time + uv2.y * resolution.y);
    float Scr = 1.0 - dot(uv2, uv2) * 0.15;
    float2 uv3 = fragCoord.xy / resolution.xy;
    float worl = fworley(uv3 * resolution.xy / 2100.0);
    worl *= exp(-length2(abs(2.0 * uv3 - 1.0)));
    worl *= abs(1.0 - 0.6 * dot(2.0 * uv3 - 1.0, 2.0 * uv3 - 1.0));
    col += float3(0.40 * worl, 0.35 * worl, 0.25 * worl);

    // Border
    float g2 = (blend_g / 2.0) + 0.39;
    float g1 = ((1.0 - blend_g) / 2.0);
    if (uv3.y >= g2 + 0.11) col *= 0.0;
    if (uv3.y >= g2 + 0.09) col *= 0.4;
    if (uv3.y >= g2 + 0.07) { if (glsl_mod(uv3.x - 0.06 * time, 0.18) <= 0.16) col *= 0.5; }
    if (uv3.y >= g2 + 0.05) { if (glsl_mod(uv3.x - 0.04 * time, 0.12) <= 0.10) col *= 0.6; }
    if (uv3.y >= g2 + 0.03) { if (glsl_mod(uv3.x - 0.02 * time, 0.08) <= 0.06) col *= 0.7; }
    if (uv3.y >= g2 + 0.01) { if (glsl_mod(uv3.x - 0.01 * time, 0.04) <= 0.02) col *= 0.8; }
    if (uv3.y <= g1 + 0.10) { if (glsl_mod(uv3.x + 0.01 * time, 0.04) <= 0.02) col *= 0.8; }
    if (uv3.y <= g1 + 0.08) { if (glsl_mod(uv3.x + 0.02 * time, 0.08) <= 0.06) col *= 0.7; }
    if (uv3.y <= g1 + 0.06) { if (glsl_mod(uv3.x + 0.04 * time, 0.12) <= 0.10) col *= 0.6; }
    if (uv3.y <= g1 + 0.04) { if (glsl_mod(uv3.x + 0.06 * time, 0.18) <= 0.16) col *= 0.5; }
    if (uv3.y <= g1 + 0.02) col *= 0.4;
    if (uv3.y <= g1 + 0.00) col *= 0.0;

    col = col * Scr * blend_g;

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
