// 80's style screen saver with simple lines
// Original: https://www.shadertoy.com/view/dsKfRz by bschu
// Line function by gPlati: https://www.shadertoy.com/view/MlcGDB

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

float lineSDF(float2 P, float2 A, float2 B, float r) {
    float2 g = B - A;
    float d = abs(dot(normalize(float2(g.y, -g.x)), P - A));
    return smoothstep(r, 0.5 * r, d);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord / resolution.xy;

    // A fancy changing color
    float r = abs(sin(time / 2.0));
    float g = abs(cos(time / 3.0));
    float b = abs(-sin(time / 4.0));

    float3 changing = float3(r, g, b);
    float3 color = (float3)(abs(cos(time / 2.0)) - 0.8);

    // Points for our lines
    float speed = 0.3;
    float x1 = sin(time * speed);
    float x2 = cos(time * speed);
    float y1 = sin(time * speed);
    float y2 = cos(time * speed);

    float l = 0.0;
    float amount = 100.0;
    float width = 0.005;

    for (float i = -amount; i < amount; i += 1.0) {
        float start = i * 0.05;
        l = lineSDF(uv, float2(x1 + start, y1 - start), float2(x2 + start, y2), width);
        color = (1.0 - l) * color + (l * changing);
    }

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
