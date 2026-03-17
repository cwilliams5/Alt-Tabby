// Galvanize Tunnel
// From Alcatraz 8K intro Galvanize
// Jochen 'Virgill' Feldkoetter
// https://www.shadertoy.com/view/MlX3Wr

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
    float s, c;
    sincos(rad, s, c);
    float z2 = c * p.z - s * p.y;
    float y2 = s * p.z + c * p.y;
    p.z = z2; p.y = y2;
    return p;
}

float3 rotYaxis(float3 p, float rad) {
    float s, c;
    sincos(rad, s, c);
    float x2 = c * p.x - s * p.z;
    float z2 = s * p.x + c * p.z;
    p.x = x2; p.z = z2;
    return p;
}

float3 rotZaxis(float3 p, float rad) {
    float s, c;
    sincos(rad, s, c);
    float x2 = c * p.x - s * p.y;
    float y2 = s * p.x + c * p.y;
    p.x = x2; p.y = y2;
    return p;
}

// Rand
float rand1(float2 co) {
    return frac(sin(dot(co.xy, float2(12.9898, 78.233))) * 43758.5453);
}

// Polynomial smooth min (IQ)
float sminPoly(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
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
    // Restructured: 6 sqrt → 3 log2 + 1 exp2 (saves 2 SFU cycles)
    // Original: sqrt(sqrt(sqrt(w1 * sqrt(w2) * sqrt(sqrt(w3)))))
    //         = w1^0.125 * w2^0.0625 * w3^0.03125
    float w1 = worley(p * 32.0 + 4.3 + time * 0.250);
    float w2 = worley(p * 64.0 + 5.3 + time * -0.125);
    float w3 = worley(p * -128.0 + 7.3);
    return exp2(0.125 * log2(w1) + 0.0625 * log2(w2) + 0.03125 * log2(w3));
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
    static const float AbsScaleRaisedTo1mIters = pow(abs(1.84), -13.0);
    float4 p = float4(pos, 1.0), p0 = float4(Julia, 1.0);
    for (int i = 0; i < 14; i++) {
        p.xyz = abs(p.xyz) + Trans;
        float r2 = dot(p.xyz, p.xyz);
        p *= saturate(max(MinRad2 / r2, MinRad2));
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
    float _sx, _cx;
    sincos(theta, _sx, _cx);
    float x = 3.0 * _cx;
    float z = 3.0 * _sx;
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

    float dif = saturate(dot(lig, nor));
    float _spec2 = saturate(dot(reflect(rd, nor), lig)); _spec2 *= _spec2;
    float _spec4 = _spec2*_spec2; float _spec8 = _spec4*_spec4; float spec = _spec8*_spec8;
    float sh = softshadow(pos, lig, 0.02, 20.0, 7.0);
    float3 color = getColor();
    col = ((0.8 * dif + spec) + 0.35 * color);
    col = col * saturate(sh);

    // Postprocessing
    float klang1 = 0.4;
    float2 uv2 = -0.3 + 2.0 * fragCoord.xy / resolution.xy;
    col -= 0.20 * (1.0 - klang1) * rand1(uv2.xy * time);
    col *= 0.9 + 0.20 * (1.0 - klang1) * sin(10.0 * time + uv2.x * resolution.x);
    col *= 0.9 + 0.20 * (1.0 - klang1) * sin(10.0 * time + uv2.y * resolution.y);
    float Scr = 1.0 - dot(uv2, uv2) * 0.15;
    float2 uv3 = fragCoord.xy / resolution.xy;
    float worl = fworley(uv3 * resolution.xy / 2100.0);
    float2 uv3_centered = 2.0 * uv3 - 1.0;
    worl *= exp(-length2(abs(uv3_centered)));
    worl *= abs(1.0 - 0.6 * dot(uv3_centered, uv3_centered));
    col += float3(0.40 * worl, 0.35 * worl, 0.25 * worl);

    // Border
    float half_blend = blend_g * 0.5;
    float g2 = half_blend + 0.39;
    float g1 = 0.5 - half_blend;
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

    return AT_PostProcess(col);
}
