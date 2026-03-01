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

#define PI 3.141592
#define TWOPI 6.283184
#define D2R (PI / 180.0)

float2x2 rotMat(float r) {
    float c = cos(r);
    float s = sin(r);
    return float2x2(c, -s, s, c);
}

float abs1d(float x) { return abs(frac(x) - 0.5); }
float2 abs2d(float2 v) { return abs(frac(v) - 0.5); }

#define OC 15.0

float3 Oilnoise(float2 pos, float3 RGB)
{
    float2 q = (float2)0;
    float result = 0.0;

    float s = 2.2;
    float gain = 0.44;
    float2 aPos = abs2d(pos) * 0.5;

    for (float i = 0.0; i < OC; i++)
    {
        pos = mul(pos, rotMat(D2R * 30.0));
        float t = (sin(time) * 0.5 + 0.5) * 0.2 + time * 0.8;
        q = pos * s + aPos + t;
        q = float2(cos(q.x), cos(q.y));

        result += abs1d(dot(q, float2(0.3, 0.3))) * gain;

        s *= 1.07;
        aPos += cos(q);
        aPos = mul(aPos, rotMat(D2R * 5.0));
        aPos *= 1.2;
    }

    result = pow(result, 4.0);
    return clamp(RGB / result, (float3)0, (float3)1);
}

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = input.pos.xy;
    float3 col = float3(0.0, 0.0, 0.0);
    float2 st = fragCoord / resolution.xy;
    st.x = ((st.x - 0.5) * (resolution.x / resolution.y)) + 0.5;

    st *= 5.0;

    col = Oilnoise(st, float3(0.30, 0.7, 1.200));

    // Darken / desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
