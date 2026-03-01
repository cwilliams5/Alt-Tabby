// Balatro Twist - yufengjie (Shadertoy 3c3SWH)
// https://www.shadertoy.com/view/3c3SWH
// Converted from GLSL to HLSL for Alt-Tabby

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

#define PI 3.141596
#define PI2 (PI * 2.0)

float2 hash(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)),
               dot(p, float2(269.5, 183.3)));
    return -1.0 + 2.0 * frac(sin(p) * 43758.5453123);
}

float noise(float2 p) {
    const float K1 = 0.366025404; // (sqrt(3)-1)/2
    const float K2 = 0.211324865; // (3-sqrt(3))/6

    float2 i = floor(p + (p.x + p.y) * K1);
    float2 a = p - i + (i.x + i.y) * K2;
    float2 o = (a.x > a.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float2 b = a - o + K2;
    float2 c = a - 1.0 + 2.0 * K2;

    float3 h = max(0.5 - float3(dot(a, a), dot(b, b), dot(c, c)), 0.0);

    float3 n = h * h * h * h * float3(
        dot(a, hash(i + 0.0)),
        dot(b, hash(i + o)),
        dot(c, hash(i + 1.0)));


    return dot(n, (float3)70.0);
}

float fbm(float2 p) {
    float a = 0.5;
    float n = 0.0;

    for (float i = 0.0; i < 8.0; i++) {
        n += a * noise(p);
        p *= 2.0;
        a *= 0.5;
    }
    return n;
}

float2x2 rotate(float ang) {
    float s = sin(ang);
    float c = cos(ang);
    return float2x2(c, -s, s, c);
}

float3 glow(float v, float r, float ins, float3 col) {
    float dist = pow(r / v, ins);
    return 1.0 - exp(-dist * col);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 uv = (fragCoord * 2.0 - resolution) / resolution.y;

    uv *= 2.0;
    float2 p = uv;

    float l = length(uv) - time * 0.3;
    p = mul(rotate(l), p);

    float n = noise(uv);
    p += n * 0.5;

    float3 c1 = float3(0.57, 0.12, 0.1);
    float3 c2 = float3(0.153, 0.541, 0.769);

    n = fbm(p * 0.4);
    float3 col = glow(n, 0.2, 2.0, c1);

    n = fbm(mul(rotate(0.1), p * 0.2));
    c2 = glow(n, 0.3, 2.0, c2);

    col = col * c2;

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
