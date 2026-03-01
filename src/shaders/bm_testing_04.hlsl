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

#define NUM_OCTAVES 5

static const float3 baseColor = float3(0.90, 0.745, 0.9);

float random(in float2 st) {
    return frac(sin(dot(st.xy, float2(12.9898, 78.233))) * 43758.5453123);
}

float noise(in float2 st) {
    float2 i = floor(st);
    float2 f = frac(st);

    float a = random(i + float2(0.0, 0.0));
    float b = random(i + float2(1.0, 0.0));
    float c = random(i + float2(0.0, 1.0));
    float d = random(i + float2(1.0, 1.0));

    float2 u = f * f * (3.0 - 2.0 * f);

    return lerp(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

float fbm(in float2 st) {
    float v = 0.0;
    float a = 0.5;

    for (int i = 0; i < NUM_OCTAVES; i++) {
        v += a * noise(st);
        st = st * 2.0;
        a *= 0.5;
    }

    return v;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 st = fragCoord / resolution.xy;

    float2 q = (float2)0.0;
    q.x = fbm(st + (float2)0.0);
    q.y = fbm(st + (float2)1.0);

    float2 r = (float2)0.0;
    r.x = fbm(st + 1.0 * q + float2(1.7, 9.2) + 0.15 * time);
    r.y = fbm(st + 1.0 * q + float2(8.3, 2.8) + 0.12 * time);

    float f = fbm(st + r);

    float coef = (f * f * f + 0.6 * f * f + 0.5 * f);

    float3 color = coef * baseColor;

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}