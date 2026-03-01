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
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float2 uv = (2.0 * fragCoord - resolution.xy) / min(resolution.x, resolution.y);

    for (float i = 1.0; i < 8.0; i++) {
        uv.y += i * 0.1 / i *
            sin(uv.x * i * i + time * 0.5) * sin(uv.y * i * i + time * 0.5);
    }

    float3 col;
    col.r = uv.y - 0.1;
    col.g = uv.y + 0.3;
    col.b = uv.y + 0.95;

    // Apply darken/desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
