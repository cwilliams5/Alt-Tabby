// Surveillance — Virgill
// https://www.shadertoy.com/view/ltV3Rz
// License: CC BY-NC-SA 3.0
// Dusty menger scene with circle-of-confusion depth of field

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

static float2 g_fragCoord;

// Circle of confusion idea by eiffie
// More interesting menger by shane
static float focalDistance = 20.0;
static const float aperature = 0.04;
static const float fudgeFactor = 0.9;
static const float shadowCone = 0.5;
static float4 orbitTrap = (float4)0;
static float3 pcoc = (float3)0;
static float rCoC_g;
static float h_g;
static float4 col = (float4)0;
static float pixelSize;

float CircleOfConfusion(float t) {
    return max(abs(focalDistance - t) * aperature, pixelSize * (1.0 + t));
}

float linstep(float a, float b, float t) {
    float v = (t - a) / (b - a);
    return clamp(v, 0.0, 1.0);
}

float3 rotXaxis(float3 p, float rad) {
    float z2 = cos(rad) * p.z - sin(rad) * p.y;
    float y2 = sin(rad) * p.z + cos(rad) * p.y;
    p.z = z2;
    p.y = y2;
    return p;
}

float3 rotYaxis(float3 p, float rad) {
    float x2 = cos(rad) * p.x - sin(rad) * p.z;
    float z2 = sin(rad) * p.x + cos(rad) * p.z;
    p.x = x2;
    p.z = z2;
    return p;
}

float3 rotZaxis(float3 p, float rad) {
    float x2 = cos(rad) * p.x - sin(rad) * p.y;
    float y2 = sin(rad) * p.x + cos(rad) * p.y;
    p.x = x2;
    p.y = y2;
    return p;
}

float rand1(float2 co) {
    return frac(sin(dot(co, float2(12.9898, 78.233))) * 43758.5453);
}

// New and interesting menger formula (shane)
float NewMenger(float3 q) {
    float3 p = abs(frac(q / 3.0) * 3.0 - 1.5);
    float d = min(max(p.x, p.y), min(max(p.y, p.z), max(p.x, p.z))) - 1.0 + 0.05;
    p = abs(frac(q) - 0.5);
    d = max(d, min(max(p.x, p.y), min(max(p.y, p.z), max(p.x, p.z))) - 1.0 / 3.0 + 0.05);
    p = abs(frac(q * 2.0) * 0.5 - 0.25);
    d = max(d, min(max(p.x, p.y), min(max(p.y, p.z), max(p.x, p.z))) - 0.5 / 3.0 - 0.015);
    p = abs(frac(q * 3.0 / 0.5) * 0.5 / 3.0 - 0.5 / 6.0);
    return max(d, min(max(p.x, p.y), min(max(p.y, p.z), max(p.x, p.z))) - 1.0 / 18.0 - 0.015);
}

float map(float3 p) {
    orbitTrap = float4(length(p) - 0.8 * p.z, length(p) - 0.8 * p.y, length(p) - 0.8 * p.x, 0.0);
    return NewMenger(p);
}

static const float ShadowContrast = 0.99;

float FuzzyShadow(float3 ro, float3 rd, float coneGrad, float rCoCp) {
    float t = rCoCp * 2.0, s = 1.0;
    for (int i = 0; i < 9; i++) {
        if (s < 0.1) continue;
        float r = rCoCp + t * coneGrad + 0.05;
        float d = map(ro + rd * t) + r * 0.6;
        s *= linstep(-r, r, d);
        t += abs(d) * (0.8 + 0.2 * rand1(g_fragCoord * (float)i));
    }
    return clamp(s * ShadowContrast + (1.0 - ShadowContrast), 0.0, 1.0);
}

static const float Cycles = 4.0;

float3 cycle_color(float3 c, float s) {
    return (float3)0.5 + 0.5 * float3(cos(s * Cycles + c.x), cos(s * Cycles + c.y), cos(s * Cycles + c.z));
}

static const float3 BaseColor = float3(0.2, 0.2, 0.2);
static const float3 OrbitStrength = float3(0.8, 0.8, 0.8);
static const float4 Xot = float4(0.6, 0.5, 0.6, 0.2);
static const float4 Yot = float4(1.0, 0.5, 0.1, 0.7);
static const float4 Zot = float4(0.7, 0.8, 1.0, 0.3);
static const float4 Rot = float4(0.7, 0.7, 0.5, 0.1);

float3 getColor() {
    orbitTrap.w = sqrt(orbitTrap.w);
    float3 orbitColor = cycle_color(Xot.xyz, orbitTrap.x) * Xot.w * orbitTrap.x
                      + cycle_color(Yot.xyz, orbitTrap.y) * Yot.w * orbitTrap.y
                      + cycle_color(Zot.xyz, orbitTrap.z) * Zot.w * orbitTrap.z
                      + cycle_color(Rot.xyz, orbitTrap.w) * Rot.w * orbitTrap.w;
    float3 color = lerp(BaseColor, 3.0 * orbitColor, OrbitStrength);
    return color;
}

void castRay(float3 ro, float3 rd) {
    float3 lig = normalize(float3(0.4 + cos((25.0 + time) * 0.33), 0.2, 0.6));
    float t = 0.0;
    for (int i = 0; i < 70; i++) {
        if (col.w > 0.999 || t > 15.0) continue;
        rCoC_g = CircleOfConfusion(t);
        h_g = map(ro) + 0.5 * rCoC_g;
        if (h_g < rCoC_g) {
            pcoc = ro - rd * abs(h_g - rCoC_g);
            float2 v = float2(rCoC_g * 0.5, 0.0);
            float3 N = normalize(float3(
                -map(pcoc - v.xyy) + map(pcoc + v.xyy),
                -map(pcoc - v.yxy) + map(pcoc + v.yxy),
                -map(pcoc - v.yyx) + map(pcoc + v.yyx)));
            float3 scol = 2.3 * getColor();
            float newdiff = clamp(dot(lig, N), 0.0, 1.0);
            float newspec = pow(clamp(dot(reflect(rd, N), lig), 0.0, 1.0), 16.0);
            float newsh = FuzzyShadow(pcoc, lig, shadowCone, rCoC_g);
            scol *= 0.5 * newdiff + newspec;
            scol *= newsh;
            float alpha = (1.0 - col.w) * linstep(-rCoC_g, rCoC_g, -h_g * 1.7);
            col += float4(scol * alpha, alpha);
        }
        h_g = abs(fudgeFactor * h_g * (0.3 + 0.05 * rand1(g_fragCoord * (float)i)));
        ro += h_g * rd;
        t += h_g;
    }
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    g_fragCoord = fragCoord;

    // Reset per-pixel mutable state
    col = (float4)0;
    orbitTrap = (float4)0;
    pcoc = (float3)0;

    focalDistance = 6.5 + 3.0 * cos((25.0 + time) * 0.133);
    pixelSize = 1.0 / resolution.y;

    float3 rd = float3(2.0 * fragCoord - resolution, resolution.y);
    rd = normalize(float3(rd.xy, sqrt(max(rd.z * rd.z - dot(rd.xy, rd.xy) * 0.2, 0.0))));

    float2 m = sin(float2(0, 1.57079632) + (25.0 + time) / 4.0);
    float2x2 rot = float2x2(m.y, m.x, -m.x, m.y);
    rd.xy = mul(rot, rd.xy);
    rd.xz = mul(rot, rd.xz);

    float3 ro = float3(0.0, 2.0, 5.0 + sin((25.0 + time) / 2.0));

    castRay(ro, rd);

    float2 uv2 = -0.3 + 2.0 * fragCoord / resolution;
    // Anti-branding noise
    col -= 0.10 * rand1(uv2 * time);

    float3 color = col.rgb * 0.7;

    // Darken / desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
