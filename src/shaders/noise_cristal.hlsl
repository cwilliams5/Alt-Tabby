cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};

#define PI 3.141592
#define TWOPI 6.283184

#define R2D 180.0/PI*
#define D2R PI/180.0*

float2x2 rotMat(float r) {
    float c = cos(r);
    float s = sin(r);
    return float2x2(c, -s, s, c);
}

float abs1d(float x) { return abs(frac(x) - 0.5); }
float2 abs2d(float2 v) { return abs(frac(v) - 0.5); }
float cos1d(float p) { return cos(p * TWOPI) * 0.25 + 0.25; }
float sin1d(float p) { return sin(p * TWOPI) * 0.25 + 0.25; }

#define OC 15.0

float3 Oilnoise(float2 pos, float3 RGB)
{
    float2 q = (float2)0.0;
    float result = 0.0;

    float s = 2.2;
    float gain = 0.44;
    float2 aPos = abs2d(pos) * 0.5;

    for (float i = 0.0; i < OC; i++)
    {
        pos = mul(rotMat(D2R 30.), pos);
        float t = (sin(time) * 0.5 + 0.5) * 0.2 + time * 0.8;
        q = pos * s + t;
        q = pos * s + aPos + t;
        q = cos(q);

        result += sin1d(dot(q, (float2)0.3)) * gain;

        s *= 1.07;
        aPos += cos(smoothstep(0.0, 0.15, q));
        aPos = mul(rotMat(D2R 5.0), aPos);
        aPos *= 1.232;
    }

    result = pow(result, 4.504);
    return clamp(RGB / abs1d(dot(q, float2(-0.240, 0.000))) * .5 / result, (float3)0.0, (float3)1.0);
}

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float3 col = (float3)0.0;
    float2 st = fragCoord / resolution.xy;
    st.x = ((st.x - 0.5) * (resolution.x / resolution.y)) + 0.5;

    st *= 3.;

    float3 rgb = float3(0.30, .8, 1.200);

    float AA = 1.0;
    float2 pix = 1.0 / resolution.xy;
    float2 aaST = (float2)0.0;

    for (float i = 0.0; i < AA; i++)
    {
        for (float j = 0.0; j < AA; j++)
        {
            aaST = st + pix * float2((i + 0.5) / AA, (j + 0.5) / AA);
            col += Oilnoise(aaST, rgb);
        }
    }

    col /= AA * AA;

    // darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // alpha from brightness, premultiply
    float alpha = max(col.r, max(col.g, col.b));
    return float4(col * alpha, alpha);
}
