// CC0: Clearly a bug - mrange
// https://www.shadertoy.com/view/33cGDj

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

    float i = 0.0;
    float d = 0.0;
    float z = frac(dot(fragCoord, sin(fragCoord))) - 0.5;
    float4 o = (float4)0;
    float4 p = (float4)0;
    float4 O = (float4)0;

    float2 r = resolution;
    [loop] for (; ++i < 77.0; z += 0.6 * d) {
        p = float4(z * normalize(float3(fragCoord - 0.5 * r, r.y)), 0.1 * time);
        p.z += time;
        O = p;

        // Rotation matrix 1 — fractal pattern transform
        float4 cv1 = cos(2.0 + O.z + float4(0, 11, 33, 0));
        p.xy = mul(float2x2(cv1.x, cv1.z, cv1.y, cv1.w), p.xy);

        // Rotation matrix 2 — the happy accident bug
        float4 cv2 = cos(O + float4(0, 11, 33, 0));
        p.xy = mul(float2x2(cv2.x, cv2.z, cv2.y, cv2.w), p.xy);

        // Color palette from position + space distortion
        O = (1.0 + sin(0.5 * O.z + length(p - O) + float4(0, 4, 3, 6)))
            / (0.5 + 2.0 * dot(O.xy, O.xy));

        // Domain repetition
        p = abs(frac(p) - 0.5);

        // Distance to nearest surface (cylinder + 2 planes)
        d = abs(min(length(p.xy) - 0.125, min(p.x, p.y) + 1e-3)) + 1e-3;

        // Accumulate lighting
        o += O.w / d * O;
    }

    // HDR tone mapping
    float3 color = tanh(o.rgb / 2e4);

    // Darken / desaturate
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
