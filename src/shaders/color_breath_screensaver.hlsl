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

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    // Normalize and center pixel coordinates
    float2 uv = (fragCoord * 2.0 - resolution) / resolution.y;

    // Round mask
    float dMask = 1.0 - length(uv);
    dMask = smoothstep(0.25, 1.0, clamp(dMask, 0.0, 1.0)) * pow(abs(sin(time * 0.888) * 1.5), 3.0);

    // Time varying pixel color using deformed uvs
    float3 col = 0.5 + 0.5 * cos(time * 1.0123 + uv.xyx + float3(0, 2, 4));

    // Output to screen
    float3 color = col * dMask;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from mask — premultiplied
    float a = dMask;
    return float4(color * a, a);
}