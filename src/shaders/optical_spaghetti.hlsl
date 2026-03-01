// Optical Spaghetti — converted from Shadertoy GLSL

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
    float2 u = fragCoord.xy;

    float i = 0.0;
    float a = 0.0;
    float d = 0.0;
    float s = 0.0;
    float t = time + 10.0;
    float r = 0.0;

    float3 p = float3(resolution, 1.0);
    u = (u + u - p.xy) / p.y;

    float4 o = (float4)0;

    for (i = 0.0; i++ < 175.0; ) {
        s = 0.004 + abs(s) * 0.1;
        d += s;

        o += s * d;
        o.r += (d * 1.5 - 5.0 / s) * 0.25;
        o.b += sin(d * 0.09 + p.z * 0.3) * 2.0 / s;
        o.g += sin(d * 0.2) * 1.0 / s;

        p = float3(u * d, d + t * 5.0);
        s = min(p.z, 1.9 + sin(p.z) * 0.15);

        for (a = 1.0; a < 2.0; a += a) {
            p += cos(t * 0.1 - p.yzx * 0.5) * 0.5;

            r = p.z * 0.1 + sin(t * 0.2);

            float2x2 rot = float2x2(cos(r), -sin(r), sin(r), cos(r));
            p.xy = mul(p.xy, rot);
            s += abs(sin(p.x * a)) * (2.2 + sin(t * 0.1) * 0.25) * -abs(sin(abs(p.y) * a) / a);
        }
    }

    o = pow(tanh(o * o / 1.5e8 * length(u)), (float4)(1.0 / 2.2));
    o *= o;

    float3 color = o.rgb;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float alpha = max(color.r, max(color.g, color.b));
    return float4(color * alpha, alpha);
}
