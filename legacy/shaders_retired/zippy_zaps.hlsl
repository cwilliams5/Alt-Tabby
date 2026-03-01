// Zippy Zaps - converted from Shadertoy (XXyGzh) by SnoopethDuckDuck
// https://www.shadertoy.com/view/XXyGzh

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
    float2 v = resolution;
    float2 u = 0.2 * (2.0 * fragCoord - v) / v.y;

    float4 z = float4(1, 2, 3, 0);
    float4 o = z;

    float a = 0.5;
    float t = time;
    float i = 0;

    [loop] for (; ++i < 19.;) {
        // Side effects extracted from original comma-operator expression
        t += 1.0;
        a += 0.03;
        v = cos(t - 7. * u * pow(a, i)) - 5. * u;

        // Rotation matrix: z.wxzw*11 = float4(0,11,33,0)
        float4 cv = cos(i + 0.02 * t - float4(0, 11, 33, 0));
        u = mul(float2x2(cv.x, cv.z, cv.y, cv.w), u);

        u += tanh(40. * dot(u, u) * cos(1e2 * u.yx + t)) / 2e2
           + 0.2 * a * u
           + cos(4. / exp(dot(o, o) / 1e2) + t) / 3e2;

        // For-loop increment expression
        o += (1. + cos(z + t))
           / length((1. + i * dot(v, v))
                  * sin(1.5 * u / (0.5 - dot(u, u)) - 9. * u.yx + t));
    }

    o = 25.6 / (min(o, 13.) + 164. / o)
      - dot(u, u) / 250.;

    float3 color = saturate(o.rgb);

    // Darken / desaturate
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Premultiplied alpha from brightness
    float al = max(color.r, max(color.g, color.b));
    return float4(color * al, al);
}
