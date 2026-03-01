// Converted from Shadertoy: Tileable Water Caustic by Dave_Hoskins
// https://www.shadertoy.com/view/MdlXz8
// Original water turbulence effect by joltz0r

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

#define TAU 6.28318530718
#define MAX_ITER 5

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float stime = time * 0.5 + 23.0;
    float2 uv = fragCoord / resolution;

    float2 p = fmod(uv * TAU, TAU) - 250.0;
    float2 i = p;
    float c = 1.0;
    float inten = 0.005;

    for (int n = 0; n < MAX_ITER; n++)
    {
        float t = stime * (1.0 - (3.5 / float(n + 1)));
        i = p + float2(cos(t - i.x) + sin(t + i.y), sin(t - i.y) + cos(t + i.x));
        c += 1.0 / length(float2(p.x / (sin(i.x + t) / inten), p.y / (cos(i.y + t) / inten)));
    }
    c /= float(MAX_ITER);
    c = 1.17 - pow(c, 1.4);
    float v = pow(abs(c), 8.0);
    float3 colour = clamp(float3(v, v, v) + float3(0.0, 0.35, 0.5), 0.0, 1.0);

    float3 color = colour;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
