// Screensaver warped grad waves
// Converted from: https://www.shadertoy.com/view/mdSXWV

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

float2 rot2(float2 st, float theta) {
    float c = cos(theta);
    float s = sin(theta);
    float2x2 M = float2x2(c, -s, s, c);
    return mul(M, st);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord / resolution;
    uv -= 0.5;
    uv *= 5.0;

    uv = rot2(uv, 0.5 * 3.1415 * uv.x);

    float3 col = 0.5 + 0.5 * cos(time + uv.xyx + float3(0, 2, 4));

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, (float3)lum, desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
