// Nebula Flight — Hazel Quantock 2014
// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.
// Converted from Shadertoy: https://www.shadertoy.com/view/Xs2SzR

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

Texture2D iChannel1 : register(t1);
SamplerState samp1 : register(s1);

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

static const float tau = 6.28318530717958647692;

// texture noise
float2 Noise(float3 x)
{
    float3 p = floor(x), f = frac(x);
    f = f * f * (3.0 - 2.0 * f);
    float2 uv = (p.xy + float2(37.0, 17.0) * p.z) + f.xy;
    float4 rg = iChannel0.SampleLevel(samp0, (uv + 0.5) / 256.0, 0.0);
    return lerp(rg.yw, rg.xz, f.z);
}

float4 Density(float3 pos)
{
    pos /= 30.0;
    float2 s = (float2)0;
    s += Noise(pos.xyz / 1.0) / 1.0;
    s += Noise(pos.zxy * 2.0) / 2.0;
    s += Noise(pos.yzx * 4.0) / 4.0;
    s += Noise(pos.xzy * 8.0) / 8.0;

    s /= 2.0 - 1.0 / 8.0;

    s.y = pow(s.y, 5.0) * 1.0;

    return float4(pow(sin(float3(1, 2, 5) + tau * s.x) * 0.5 + 0.5, (float3)1.0) * 16.0, s.y);
}

float3 Path(float t)
{
    t *= 0.2;
    float2 a = float2(1, 0.3) * t;
    float r = sin(t * 1.2) * 0.2 + 0.8;

    float2 cs = float2(cos(a.y), sin(a.y));
    return 100.0 * r * float3(cos(a.x), 1, sin(a.x)) * cs.xyx;
}

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = input.pos.xy;
    float T = time;

    float3 pos = Path(T);

    float d = 0.5;
    float3 pa = Path(T + d), pb = Path(T - d);
    float3 sky = (pa + pb) / 2.0 - pos;

    // alternate between looking forward and looking toward centre of nebula
    float3 forward = normalize(lerp(normalize(pa - pb), normalize((float3)0 - pos), smoothstep(-0.2, 0.2, sin(T * 0.2))));
    float3 right = normalize(cross(sky, forward));
    float3 up = normalize(cross(forward, right));

    float2 uv = (fragCoord.xy - resolution.xy * 0.5) / resolution.y;
    float3 ray = forward * 1.0 + right * uv.x + up * uv.y;
    ray = normalize(ray);

    float3 c = (float3)0;
    float t = 0.0;
    float baseStride = 3.0;
    float stride = baseStride;
    float visibility = 1.0;
    for (int i = 0; i < 30; i++)
    {
        if (visibility < 0.001) break;

        float4 samplev = Density(pos + t * ray);
        float visibilityAfterSpan = pow(1.0 - samplev.a, stride);

        samplev.rgb *= samplev.a;

        c += samplev.rgb * visibility * (1.0 - visibilityAfterSpan);
        visibility *= visibilityAfterSpan;

        float newStride = baseStride / lerp(1.0, visibility, 0.3);
        t += (stride + newStride) * 0.5;
        stride = newStride;
    }

    c = pow(c, (float3)(1.0 / 2.2));

    // dithering
    c += (iChannel1.SampleLevel(samp1, (fragCoord.xy + 0.5) / 8.0, 0.0).x - 0.5) / 256.0;

    // darken / desaturate
    float lum = dot(c, float3(0.299, 0.587, 0.114));
    c = lerp(c, float3(lum, lum, lum), desaturate);
    c = c * (1.0 - darken);

    // alpha from brightness, premultiply
    float a = max(c.r, max(c.g, c.b));
    return float4(c * a, a);
}