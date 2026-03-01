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

    float speed = 1.5;
    int starCount = 600;
    float starSize = 0.0015;
    float minZ = 0.3;

    float2 uv = (2.0 * fragCoord - resolution) / resolution.y;

    float3 color = (float3)0.0;

    for (int i = 0; i < starCount; i++) {
        float seed = float(i) * 0.01337;

        float2 starXY = float2(
            frac(sin(seed * 734.631) * 5623.541) * 2.0 - 1.0,
            frac(cos(seed * 423.891) * 3245.721) * 2.0 - 1.0);

        float z = fmod(time * speed * -0.2 + seed, 1.0) + minZ * 0.1;

        float size = starSize / z;
        float brightness = 0.7 / z;

        float2 starUV = uv - starXY * (0.5 / z);
        float star = smoothstep(size, 0.0, length(starUV));

        color += (float3)(star * brightness);
    }

    color = min(color, (float3)1.0);
    color *= 0.9 + 0.1 * sin(fragCoord.y * 3.14159 * 2.0); // scanlines

    // Post-processing: darken/desaturate
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
