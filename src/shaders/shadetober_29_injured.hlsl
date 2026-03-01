// shadetober #29 (injured) — percentcer (Shadertoy tscSWf)
// CC BY-NC-SA 3.0
// Converted from GLSL to HLSL for Alt-Tabby
// Domain warping FBM based on https://iquilezles.org/articles/warp

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

float noise(float3 p) {
    float3 ip = floor(p);
    p -= ip;
    float3 s = float3(7, 157, 113);
    float4 h = float4(0.0, s.yz, s.y + s.z) + dot(ip, s);
    p = p * p * (3.0 - 2.0 * p);
    h = lerp(frac(sin(h) * 43758.5), frac(sin(h + s.x) * 43758.5), p.x);
    h.xy = lerp(h.xz, h.yw, p.y);
    return lerp(h.x, h.y, p.z);
}

float fbm(float2 x, float hurst) {
    float gain = exp2(-hurst);
    float f = 1.0;
    float a = 1.0;
    float t = 0.0;
    [unroll]
    for (int i = 0; i < 4; i++) {
        t += a * noise((f * x).xyy);
        f *= 2.0;
        a *= gain;
    }
    return t;
}

float3 fbms(float2 uv) {
    float h = 1.0;
    float2 t1 = float2(fbm(uv, h), fbm(uv + float2(4.3, -2.1) * sin(time * 0.02), h));
    float2 t2 = float2(fbm(uv + 2.0 * t1 + float2(-1.9, 3.9) * cos(time * 0.07), h),
                        fbm(uv + 2.0 * t1 + float2(2.2, 3.1) * sin(time * 0.05), h));
    float t3 = fbm(uv + 2.0 * t2 + float2(5.6, 1.4) * cos(time * 0.06), h);
    return float3(t3, t3 - 1.0, t3 - 1.0);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 uv = (2.0 * fragCoord - resolution.xy) / resolution.y;
    uv *= 2.0;
    uv += 10.0;
    float3 c = fbms(uv);

    // Darken/desaturate post-processing
    float lum = dot(c, float3(0.299, 0.587, 0.114));
    c = lerp(c, (float3)lum, desaturate);
    c = c * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(c.r, max(c.g, c.b));
    return float4(c * a, a);
}
