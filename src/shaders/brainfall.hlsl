// Brainfall — based on https://www.shadertoy.com/view/XXG3zG
// Original by panna_pudi

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

static const float PI = 3.14159265359;
static const float TAU = 2.0 * PI;

float3 PBRNeutralToneMapping(float3 color) {
    const float startCompression = 0.8 - 0.04;
    const float desat = 0.15;

    float x = min(color.r, min(color.g, color.b));
    float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
    color -= offset;

    float peak = max(color.r, max(color.g, color.b));
    if (peak < startCompression)
        return color;

    const float d = 1.0 - startCompression;
    float newPeak = 1.0 - d * d / (peak + d - startCompression);
    color *= newPeak / peak;

    float g = 1.0 - 1.0 / (desat * (peak - newPeak) + 1.0);
    return lerp(color, (float3)newPeak, g);
}

// Rotation matrix — same constructor args as GLSL for mul(v, m) pattern
float2x2 rot(float x) {
    float c = cos(x), s = sin(x);
    return float2x2(c, -s, s, c);
}

float zuzoise(float2 uv, float t) {
    float2 sine_acc = (float2)0;
    float2 res = (float2)0;
    float scale = 5.0;

    float2x2 m = rot(1.0);

    for (float i = 0.0; i < 15.0; i++) {
        uv = mul(uv, m);
        sine_acc = mul(sine_acc, m);
        float2 layer = uv * scale * i + sine_acc - t;
        sine_acc += sin(layer);
        res += (cos(layer) * 0.5 + 0.5) / scale;
        scale *= 1.2;
    }
    return dot(res, (float2)1);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = (fragCoord / resolution - 0.5)
                * float2(resolution.x / resolution.y, 1.0);
    uv *= 0.2;

    float t = time;

    float a = sin(t * 0.1) * sin(t * 0.13 + dot(uv, uv) * 1.5) * 4.0;
    uv = mul(uv, rot(a));

    float3 sp = float3(uv, 0.0);

    const float L = 7.0;
    const float gfreq = 0.7;
    float sum = 0.0;

    float th = PI * 0.7071 / L;
    float cs = cos(th), si = sin(th);
    // Transposed constructor args for mul(M, v) pattern
    float2x2 M = float2x2(cs, si, -si, cs);

    float3 col = (float3)0;

    float f = 0.0;
    float2 offs = (float2)0.2;

    for (float i = 0.0; i < L; i++) {
        float s = frac((i - t * 2.0) / L);
        float e = exp2(s * L) * gfreq;

        float amp = (1.0 - cos(s * TAU)) / 3.0;

        float tmod = t * 3.0;
        tmod = tmod - sin(tmod);
        f += zuzoise(mul(M, sp.xy) * e + offs, tmod) * amp;

        sum += amp;

        M = mul(M, M);
    }

    sum = max(sum, 0.001);

    f /= sum;

    col = float3(1.0, 0.0, 0.5) * smoothstep(1.37, 1.5, f);
    col += float3(0.0, 1.0, 0.5) * pow(smoothstep(1.0, 1.54, f), 10.0);
    col += float3(0.20, 0.20, 0.20) * smoothstep(0.0, 4.59, f - 0.12);

    col = PBRNeutralToneMapping(col);

    col = pow(col, (float3)0.4545);

    float3 color = col;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, (float3)lum, desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float outA = max(color.r, max(color.g, color.b));
    return float4(color * outA, outA);
}
