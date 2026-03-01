// Converted from Shadertoy: Chill Smoke Orb by diatribes
// https://www.shadertoy.com/view/tflBDM

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

float2x2 rot(float angle) {
    float4 c = cos(angle + float4(0, 33, 11, 0));
    return float2x2(c.x, c.z, c.y, c.w);
}

float orb(float3 p, float gtime) {
    float t = gtime * 4.0;
    return length(p - float3(
        sin(sin(t * 0.2) + t * 0.4) * 6.0,
        1.0 + sin(sin(t * 0.5) + t * 0.2) * 4.0,
        12.0 + gtime + cos(t * 0.3) * 8.0));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float d = 0.0, a, e = 0.0, s = 0.0, t = time;
    float4 o = (float4)0;

    // scale coords
    float2 uv = (2.0 * fragCoord - resolution) / resolution.y;

    // camera movement
    uv += float2(cos(t * 0.1) * 0.3, cos(t * 0.3) * 0.1);

    for (float i = 0.0; i < 128.0; i += 1.0)
    {
        // ray position
        float3 p = float3(uv * d, d + t);

        // entity (orb)
        e = orb(p, time) - 0.1;

        // spin by t, twist by p.z
        p.xy = mul(rot(0.1 * t + p.z / 8.0), p.xy);

        // mirrored planes 4 units apart
        s = 4.0 - abs(p.y);

        // noise octaves
        for (a = 0.8; a < 32.0; a += a)
        {
            // apply turbulence
            p += cos(0.7 * t + p.yzx) * 0.2;

            // apply noise
            s -= abs(dot(sin(0.1 * t + p * a), (float3)0.6)) / a;
        }

        // accumulate distance
        e = max(0.5 * e, 0.01);
        s = min(0.03 + 0.2 * abs(s), e);
        d += s;

        // grayscale color and orb light
        o += 1.0 / (s + e * 3.0);
    }

    // tanh tonemap
    o = tanh(o / 1e1);

    float3 color = o.rgb;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float al = max(color.r, max(color.g, color.b));
    return float4(color * al, al);
}
