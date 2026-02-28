// Nox — based on https://www.shadertoy.com/view/WfKGRD
// Original by diatribes
// Cloud tunnel with moon - noise, turbulence, and translucency

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

    float d = 0, s = 0, n = 0;
    float t = time * 0.05;
    float2 u = (fragCoord - resolution * 0.5) / resolution.y;

    float4 o = (float4)0;

    for (int iter = 0; iter < 100; iter++) {
        float3 p = float3(u * d, d + t * 4.0);
        p += cos(p.z + t + p.yzx * 0.5) * 0.5;
        s = 5.0 - length(p.xy);

        // Inner noise loop — GLSL used mat2(cos(vec4)) golf trick
        for (n = 0.06; n < 2.0; n += n) {
            float4 rv = cos(t * 0.1 + float4(0, 33, 11, 0));
            // GLSL mat2(v4) fills column-major; for mul(v, m) pattern
            // HLSL float2x2 with same component order works
            p.xy = mul(p.xy, float2x2(rv.x, rv.y, rv.z, rv.w));
            s -= abs(dot(sin(p.z + t + p * n * 20.0), (float3)0.05)) / n;
        }

        s = 0.02 + abs(s) * 0.1;
        d += s;
        o += 1.0 / s;
    }

    o = tanh(o / d / 9e2 / length(u));

    float3 color = o.rgb;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, (float3)lum, desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float outA = max(color.r, max(color.g, color.b));
    return float4(color * outA, outA);
}
