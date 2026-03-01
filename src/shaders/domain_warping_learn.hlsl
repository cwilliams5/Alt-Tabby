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

#define octaves 6

float random(float2 uv) {
    return frac((sin(dot(uv.xy, float2(12.9898, 78.233)))) * 43758.5453123);
}

float noise(float2 uv) {
    float2 i = floor(uv);
    float2 f = frac(uv);

    float a = random(i);
    float b = random(i + float2(1.0, 0.0));
    float c = random(i + float2(0.0, 1.0));
    float d = random(i + float2(1.0, 1.0));

    float2 u = f * f * (3.0 - 2.0 * f);

    float v1 = lerp(a, b, u.x);
    float v2 = lerp(c, d, u.x);
    return lerp(v1, v2, u.y);
}

float3 palette(float t) {
    float3 a = float3(0.000, 0.500, 0.500);
    float3 b = float3(0.000, 0.500, 0.500);
    float3 c = float3(0.000, 0.500, 0.333);
    float3 d = float3(0.000, 0.500, 0.667);
    return a + b * cos(6.28318 * (c * t + d));
}

float fbm(float2 uv) {
    float lacunarity = 2.0;
    float gain = 0.5;

    float amplitude = 0.5;
    float frequency = 1.0;

    float result = 0.0;

    for (int i = 0; i < octaves; i++) {
        result += amplitude * noise(frequency * uv);
        frequency *= lacunarity;
        amplitude *= gain;
    }
    return result;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = (fragCoord.xy - resolution.xy * 0.5) / resolution.y * 10.0;

    float uvt = sin(length(uv) - time);
    float2 uv2 = uv * fbm(uv) * uvt;

    float3 col = palette(fbm(uv2));

    // Apply darken/desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
