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

static const int octaves = 6;

float2 random2(float2 st) {
    float2 t = float2(iChannel0.Sample(samp0, st / 1023.0).x, iChannel0.Sample(samp0, st / 1023.0 + 0.5).x);
    return t * t * 4.0;
}

// Value Noise by Inigo Quilez - iq/2013
float noise(float2 st) {
    float2 i = floor(st);
    float2 f = frac(st);

    float2 u = f * f * (3.0 - 2.0 * f);

    return lerp(lerp(dot(random2(i + float2(0.0, 0.0)), f - float2(0.0, 0.0)),
                     dot(random2(i + float2(1.0, 0.0)), f - float2(1.0, 0.0)), u.x),
                lerp(dot(random2(i + float2(0.0, 1.0)), f - float2(0.0, 1.0)),
                     dot(random2(i + float2(1.0, 1.0)), f - float2(1.0, 1.0)), u.x), u.y);
}

float fbm1(in float2 _st) {
    float v = 0.0;
    float a = 0.5;
    float2 shift = (float2)100.0;
    // Rotate to reduce axial bias
    float2x2 rot = float2x2(cos(0.5), sin(0.5),
                             -sin(0.5), cos(0.5));
    for (int i = 0; i < octaves; ++i) {
        v += a * noise(_st);
        _st = mul(rot, _st) * 2.0 + shift;
        a *= 0.4;
    }
    return v;
}

float pattern(float2 uv, float t, inout float2 q, inout float2 r) {
    q = float2(fbm1(uv * 0.1 + float2(0.0, 0.0)),
               fbm1(uv + float2(5.2, 1.3)));

    r = float2(fbm1(uv * 0.1 + 4.0 * q + float2(1.7 - t / 2.0, 9.2)),
               fbm1(uv + 4.0 * q + float2(8.3 - t / 2.0, 2.8)));

    float2 s = float2(fbm1(uv + 5.0 * r + float2(21.7 - t / 2.0, 90.2)),
                      fbm1(uv * 0.05 + 5.0 * r + float2(80.3 - t / 2.0, 20.8))) * 0.25;

    return fbm1(uv * 0.05 + 4.0 * s);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = (fragCoord - 0.5 * resolution.xy) / min(resolution.y, resolution.x);

    float t = time / 10.0;

    float2x2 rot = float2x2(cos(t / 10.0), sin(t / 10.0),
                             -sin(t / 10.0), cos(t / 10.0));

    uv = mul(rot, uv);
    uv *= 0.9 * sin(t) + 3.0;
    uv.x -= t / 5.0;

    float2 q = (float2)0.0;
    float2 r = (float2)0.0;

    float _pattern = pattern(uv, t, q, r);

    float3 colour = (float3)(_pattern * 2.0);
    colour.r -= dot(q, r) * 15.0;
    colour = lerp(colour, float3(pattern(r, t, q, r), dot(q, r) * 15.0, -0.1), 0.5);
    colour -= q.y * 1.5;
    colour = lerp(colour, float3(0.2, 0.2, 0.2), clamp(q.x, -1.0, 0.0) * 3.0);

    float3 col = -colour + abs(colour) * 2.0;
    float alphaOrig = 1.0 / length(q);

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = saturate(alphaOrig) * max(col.r, max(col.g, col.b));
    return float4(col * saturate(alphaOrig), a);
}