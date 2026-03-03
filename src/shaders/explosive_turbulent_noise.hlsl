// Explosive Turbulent Noise by OctopusX
// Ported from https://www.shadertoy.com/view/3lsSR7
// FBM with domain warping, billowed noise

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

#define UVScale 0.4
#define Speed 0.6

#define FBM_WarpPrimary  -0.24
#define FBM_WarpSecond    0.29
#define FBM_WarpPersist   0.78
#define FBM_EvalPersist   0.62
#define FBM_Persistence   0.5
#define FBM_Lacunarity    2.2
#define FBM_Octaves       5

// Fork from Dave Hoskins - https://www.shadertoy.com/view/4djSRW
float4 hash43(float3 p) {
    float4 p4 = frac(p.xyzx * float4(1031.0, 0.1030, 0.0973, 0.1099));
    p4 += dot(p4, p4.wzxy + 19.19);
    return -1.0 + 2.0 * frac(float4(
        (p4.x + p4.y) * p4.z, (p4.x + p4.z) * p4.y,
        (p4.y + p4.z) * p4.w, (p4.z + p4.w) * p4.x));
}

// Offsets for noise
static const float3 nbs[8] = {
    float3(0, 0, 0), float3(0, 1, 0), float3(1, 0, 0), float3(1, 1, 0),
    float3(0, 0, 1), float3(0, 1, 1), float3(1, 0, 1), float3(1, 1, 1)
};

// Value simplex noise - forked from https://www.shadertoy.com/view/XltXRH
float4 AchNoise3D(float3 x) {
    float3 p = floor(x);
    float3 fr = smoothstep(0.0, 1.0, frac(x));
    float4 L1C1 = lerp(hash43(p + nbs[0]), hash43(p + nbs[2]), fr.x);
    float4 L1C2 = lerp(hash43(p + nbs[1]), hash43(p + nbs[3]), fr.x);
    float4 L1C3 = lerp(hash43(p + nbs[4]), hash43(p + nbs[6]), fr.x);
    float4 L1C4 = lerp(hash43(p + nbs[5]), hash43(p + nbs[7]), fr.x);
    float4 L2C1 = lerp(L1C1, L1C2, fr.y);
    float4 L2C2 = lerp(L1C3, L1C4, fr.y);
    return lerp(L2C1, L2C2, fr.z);
}

float4 ValueSimplex3D(float3 p) {
    float4 a = AchNoise3D(p);
    float4 b = AchNoise3D(p + 120.5);
    return (a + b) * 0.5;
}

float4 FBM(float3 p) {
    float4 f = (float4)0, s = (float4)0, n = (float4)0;
    float a = 1.0, w = 0.0;
    [loop]
    for (int i = 0; i < FBM_Octaves; i++) {
        n = ValueSimplex3D(p);
        f += abs(n) * a;
        s += n.zwxy * a;
        a *= FBM_Persistence;
        w *= FBM_WarpPersist;
        p *= FBM_Lacunarity;
        p += n.xyz * FBM_WarpPrimary * w;
        p += s.xyz * FBM_WarpSecond;
        p.z *= FBM_EvalPersist + (f.w * 0.5 + 0.5) * 0.015;
    }
    return f;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float aspect = resolution.x / resolution.y;
    float2 uv = fragCoord / (resolution / UVScale * 0.1);
    uv.x *= aspect;

    float4 fbm_val = FBM(float3(uv, time * Speed + 100.0));
    float explosionGrad = dot(fbm_val.xyzw, fbm_val.yxwx) * 0.5;
    explosionGrad = pow(explosionGrad, 1.3);
    explosionGrad = smoothstep(0.0, 1.0, explosionGrad);

    float3 color0 = float3(1.2, 0.0, 0.0);
    float3 color1 = float3(0.9, 0.7, 0.3);

    float3 color = explosionGrad * lerp(color0, color1, explosionGrad) * 1.2 + 0.05;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, (float3)lum, desaturate);
    color *= 1.0 - darken;

    // Alpha from brightness, premultiply
    float alpha = max(color.r, max(color.g, color.b));
    return float4(color * alpha, alpha);
}
