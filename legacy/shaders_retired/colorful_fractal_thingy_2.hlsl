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

float3 palette(float t) {
    float3 a = float3(0.2, 0.4, 0.6);
    float3 b = float3(0.1, 0.2, 0.3);
    float3 c = float3(0.3, 0.5, 0.7);

    return a + b * sin(6.0 * (c * t + a));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = (fragCoord * 1000.0 / resolution.xy) / resolution.y;
    float2 uv0 = sin(uv * 2.5);

    float3 finalColor = (float3)0.5;

    for (float i = 0.0; i < 3.3; i++) {
        uv = uv * 1.5 + sin(uv.yx * 3.0) * 1.5;

        float dist = length(uv) * exp(-length(uv0 * 0.5));

        float3 col = palette(length(uv0) + i * 0.3 + time * 0.3);

        dist = sin(dist * 3.33 + time * 1.0) / 15.0;
        dist = abs(dist);
        dist = pow(0.025 / dist, 1.5);

        finalColor += col - dist;
    }

    // Darken/desaturate post-processing
    float lum = dot(finalColor, float3(0.299, 0.587, 0.114));
    finalColor = lerp(finalColor, float3(lum, lum, lum), desaturate);
    finalColor = finalColor * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(finalColor.r, max(finalColor.g, finalColor.b));
    return float4(finalColor * a, a);
}
