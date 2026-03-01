// Fire and Water — converted from Shadertoy XctBWl by zhizi
// Rotating comet effect with particle trails
// License: CC BY-NC-SA 3.0

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

static const float PI = 3.14159265857;
static const float speedfactor = 1.0;
static const float particlenums = 45.0;

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float unit = PI / 280.0;
    float intensityfactor = 1.0 / particlenums / 15000.0;

    float2 uv = fragCoord / resolution;
    float aspect = resolution.x / resolution.y;
    uv = (uv - float2(0.5, 0.5)) * float2(aspect, 1.0);

    float3 color = (float3)0.0;

    [loop]
    for (float i = 0.0; i < particlenums; i++) {
        float t = unit * i + time * speedfactor;
        float2 orbit = float2(sin(t), cos(t)) * 0.35;

        float2 fuv = 1.25 * uv + orbit;
        float3 fire = float3(0.7, 0.2, 0.1) / (float3)length(fuv) * pow(i, 2.0);
        color += fire;

        float2 wuv = 1.25 * uv - orbit;
        float3 water = float3(0.1, 0.2, 0.7) / (float3)length(wuv) * pow(i, 2.0);
        color += water;
    }

    color = color * intensityfactor;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
