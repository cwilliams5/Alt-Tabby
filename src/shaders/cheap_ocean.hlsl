// Cheap Ocean - converted from Shadertoy (NdtXDN) by Krischan
// https://www.shadertoy.com/view/NdtXDN
// License: CC BY-NC-SA 3.0

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

float2x2 rotate2D(float r) {
    return float2x2(cos(r), sin(r), -sin(r), cos(r));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float e = 0, f = 0, s = 0, g = 0, k = 0.01;
    float o = 1;

    for (int i = 0; i < 100; i++) {
        s = 2.0;
        g += min(f, max(0.03, e)) * 0.3;
        float3 p = float3((fragCoord - resolution / s) / resolution.y * g, g - s);
        p.yz = mul(rotate2D(-0.8), p.yz);
        p.y *= 2.5;
        p.z += time * 1.3;
        e = p.y;
        f = p.y;
        for (; s < 50.0;) {
            s /= 0.66;
            p.xz = mul(rotate2D(s), p.xz);
            e += abs(dot(sin(p * s) / s, (float3)0.6));
            f += abs(dot(sin(p.xz * s * 0.33 + time * 0.5) / s, (float2)1.0));
        }

        if (f > k * k)
            o += e * o * k;
        else
            o += -exp(-f * f) * o * k;
    }

    float3 color = o * float3(0.33, 0.7, 0.85);

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
