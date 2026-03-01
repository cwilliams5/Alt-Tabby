// Color Fade Pattern - IceSelkie (Shadertoy wsfSDN)
// https://www.shadertoy.com/view/wsfSDN
// Converted from GLSL to HLSL for Alt-Tabby
// Note: Dead ray marcher scaffolding removed (march() always returned 1.0)

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

float getLight(float3 pt) {
    return pt.z - 1.0;
}

float3 getColor(float3 pt) {
    pt.z = pt.x + pt.y * 0.3;
    return 0.5 + 0.5 * cos((0.3 * time * float3(1.0, 0.95, 1.06)) + pt.xyz * 0.2);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    // Normalized pixel coordinates (-1 to 1)
    float2 uv = (fragCoord - 0.5 * resolution) / resolution.y;

    // Camera location & look direction
    float3 cam = float3(0, 0, 1);
    float3 look = normalize(float3(uv.x, uv.y, 1));

    // march() always returns 1.0 in original
    float d = 1.0;
    float3 pt = cam + d * look;
    float3 col = getLight(pt) * getColor(pt);

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
