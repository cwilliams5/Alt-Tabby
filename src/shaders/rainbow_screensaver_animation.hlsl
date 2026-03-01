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

// cosine based palette, 4 float3 params
float3 palette(float t, float3 a, float3 b, float3 c, float3 d)
{
    return a + b * cos(6.28318 * (c * t + d));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    // Normalized pixel coordinates (from 0 to 1)
    float2 uv = fragCoord / resolution;

    float t = time * 0.2;

    // Calculate two points on screen.
    float2 c1 = float2(sin(t) * 0.5, cos(time) * 0.7);
    float2 c2 = float2(sin(t * 0.7) * 0.9, cos(time * 0.65) * 0.6);

    // Determine length to point 1 & calculate color.
    float d1 = length(uv - c1);
    float3 col1 = palette(d1 + t, float3(0.5, 0.5, 0.5), float3(0.5, 0.5, 0.5), float3(1.0, 1.0, 1.0), float3(0.0, 0.33, 0.67));

    // Determine length to point 2 & calculate color.
    float d2 = length(uv - c2);
    float3 col2 = palette(d2 + t, float3(0.5, 0.5, 0.5), float3(0.5, 0.5, 0.5), float3(1.0, 1.0, 1.0), float3(0.0, 0.33, 0.67));

    // Output to screen
    float3 color = (col1 + col2) / 2.0;

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
