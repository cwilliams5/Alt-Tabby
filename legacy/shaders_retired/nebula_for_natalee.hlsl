cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};

Texture2D iChannel0 : register(t0);
SamplerState samp0 : register(s0);

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

float fbm(float2 uv) {
    float f = 0.5;

    float amp = 0.5;
    float freq = 2.0;
    for (int i = 0; i < 5; i++) {
        f += amp * (iChannel0.Sample(samp0, uv).r - 0.5);

        uv *= freq;
        uv += 10.0;

        freq *= 2.0;
        amp *= 0.5;
    }

    return f;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord / resolution.xy;

    float x0 = fbm(uv * 0.1 + time * 0.007);
    float y0 = fbm(uv * 0.1523 + time * 0.007);

    float3 col = (float3)0.0;

    float amp = 0.5;
    float freq = 0.1;

    float2 off = float2(x0, y0);

    float ff = 0.0;

    for (int i = 0; i < 8; i++) {
        float f = fbm(uv * freq + off * 0.03 + ff * 0.02 + time * 0.0004 * (8.0 - float(i)));

        f = pow(f + 0.25, float(i) * 6.2 + 5.5);
        ff += f;

        float r = sin(x0 * 18.0);
        float g = sin(y0 * 13.0 + 1.7);
        float b = sin(f * 11.0 + 1.1);

        col += amp * f * lerp(float3(0.3, 0.5, 0.9), float3(r, g, b), pow(float(i) / 8.0, f));

        amp *= 0.9;
        freq *= 2.7;
    }

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}