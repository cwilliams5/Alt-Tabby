// Smoke Flythrough — volumetric smoke tunnel
// https://www.shadertoy.com/view/ms3GDs
// Author: Poisson | License: CC BY-NC-SA 3.0

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

#define NUM_STEPS 256

// aces tonemapping
float3 ACES(float3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return (x * (a * x + b)) / (x * (c * x + d) + e);
}

// camera path
float2 camPath(float t) {
    return float2(0.4 * sin(t), 0.4 * cos(t * 0.5));
}

float hash(float n) { return frac(sin(n) * 43758.5453123); }

// procedural 3D hash (replaces volume texture)
float hash3d(float3 p) {
    p = frac(p * float3(443.8975, 397.2973, 491.1871));
    p += dot(p, p.yzx + 19.19);
    return frac((p.x + p.y) * p.z);
}

// 3d value noise (replaces volume texture lookup)
float noise(float3 x) {
    float3 i = floor(x);
    float3 f = frac(x);
    f = f * f * (3.0 - 2.0 * f);

    float a = hash3d(i);
    float b = hash3d(i + float3(1, 0, 0));
    float c = hash3d(i + float3(0, 1, 0));
    float d = hash3d(i + float3(1, 1, 0));
    float e = hash3d(i + float3(0, 0, 1));
    float f0 = hash3d(i + float3(1, 0, 1));
    float g = hash3d(i + float3(0, 1, 1));
    float h = hash3d(i + float3(1, 1, 1));

    return lerp(lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y),
                lerp(lerp(e, f0, f.x), lerp(g, h, f.x), f.y), f.z);
}

// smooth minimum (iq)
float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

// volume density
float map(float3 p) {
    float f = 0.0;

    float3 q = p;
    p *= 3.0;
    f += 0.5 * noise(p);
    f += 0.25 * noise(2.0 * p);
    f += 0.0625 * noise(7.0 * p);
    f += 0.03125 * noise(16.0 * p);
    f -= 0.35;

    q.xy -= camPath(q.z);
    f = smin(f, 0.1 - length(q.xy), -0.4);

    return -256.0 * f;
}

// light intensity
float getLight(float h, float k, float3 ce, float3 p) {
    float3 lig = ce - p;
    float llig = length(lig);
    lig = normalize(lig);
    float sha = clamp((h - map(p + lig * k)) / 128.0, 0.0, 1.0);
    float att = 1.0 / (llig * llig);
    return sha * att;
}

// volumetric rendering
float3 render(float3 ro, float3 rd, float2 fragCoord) {
    float tmax = 6.0;
    float s = tmax / float(NUM_STEPS);
    float t = 0.0;
    // dithering
    t += s * hash(fragCoord.x * 8315.9213 / resolution.x + fragCoord.y * 2942.5192 / resolution.y);
    float4 sum = float4(0, 0, 0, 1);

    for (int i = 0; i < NUM_STEPS; i++) {
        float3 p = ro + rd * t;
        float h = map(p);

        if (h > 0.0) {
            float occ = exp(-h * 0.1);

            float k = 0.08;
            float3 col = 3.0 * float3(0.3, 0.6, 1) * getLight(h, k, ro + float3(1, 0, 2), p) * occ
                       + 3.0 * float3(1, 0.2, 0.1) * getLight(h, k, ro + float3(-1, 0, 2.5), p) * occ;

            sum.rgb += h * s * sum.a * col;
            sum.a *= exp(-h * s);
        }

        if (sum.a < 0.01) break;
        t += s;
    }

    return sum.rgb;
}

// camera
float3x3 setCamera(float3 ro, float3 ta) {
    float3 w = normalize(ta - ro);
    float3 u = normalize(cross(w, float3(0, 1, 0)));
    float3 v = cross(u, w);
    return float3x3(u, v, w);
}

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    float2 p = (fragCoord - 0.5 * resolution) / resolution.y;

    float3 ro = float3(0, 0, time);
    float3 ta = ro + float3(0, 0, 1);

    ro.xy += camPath(ro.z);
    ta.xy += camPath(ta.z);

    float3x3 ca = setCamera(ro, ta);
    float3 rd = mul(normalize(float3(p, 1.5)), ca);

    float3 col = render(ro, rd, fragCoord);

    col = ACES(col);
    col = pow(col, float3(0.4545, 0.4545, 0.4545));

    // vignette
    float2 q = fragCoord / resolution;
    col *= pow(16.0 * q.x * q.y * (1.0 - q.x) * (1.0 - q.y), 0.1);

    // darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}