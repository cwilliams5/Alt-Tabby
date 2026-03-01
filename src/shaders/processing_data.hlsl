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

float N21(float2 uv) { return frac(sin(uv.x * 21.281 + uv.y * 93.182) * 5821.92); }

float lineFn(float2 uv) { return smoothstep(0.0, 0.05, uv.x) - smoothstep(0.0, 0.95, uv.x); }

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = (fragCoord / resolution) * 2.0 - 1.0;

    float2 offset = abs(uv.yx) / float2(30.0, 5.2);
    uv = uv + uv * offset * offset;
    uv = uv * 0.5 + 0.5;

    float2 sc = float2(128.0, 90.0);

    float2 lUV = frac(uv * sc);
    float2 gID = floor(uv * sc);

    float rowNoise = N21(float2(0.0, gID.y));
    float dir = ((rowNoise * 2.0) - 1.0) + 0.2;
    gID.x += floor(time * dir * 30.0);

    float cellNoise = N21(gID);
    float drawBlock = (float)(cellNoise > 0.38);
    int even = (int)gID.y % 2;

    float3 col = (float3)lineFn(lUV) * drawBlock * (float)even;
    col *= frac(sin(gID.y)) + 0.24;
    col *= float3(0.224, 0.996, 0.557);

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
