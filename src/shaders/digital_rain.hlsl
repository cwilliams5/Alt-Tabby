// Digital Rain by WillKirkby
// https://www.shadertoy.com/view/ldccW4
// Converted from Shadertoy GLSL to HLSL for Alt-Tabby
// License: CC BY-NC-SA 3.0
// Y-axis: flipped (rain falls downward)

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
Texture2D iChannel1 : register(t1);
SamplerState samp0 : register(s0);
SamplerState samp1 : register(s1);

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

// iChannel1 is 256x256
static const float2 iChannel1Res = float2(256.0, 256.0);

float text(float2 fragCoord)
{
    float2 uv = fmod(fragCoord.xy, 16.0) * 0.0625;
    float2 block = fragCoord * 0.0625 - uv;
    uv = uv * 0.8 + 0.1;
    uv += floor(iChannel1.Sample(samp1, block / iChannel1Res + time * 0.002).xy * 16.0);
    uv *= 0.0625;
    uv.x = -uv.x;
    return iChannel0.Sample(samp0, uv).r;
}

float3 rain(float2 fragCoord)
{
    fragCoord.x -= fmod(fragCoord.x, 16.0);

    float offset = sin(fragCoord.x * 15.0);
    float speed = cos(fragCoord.x * 3.0) * 0.3 + 0.7;

    float y = frac(fragCoord.y / resolution.y + time * speed + offset);
    return float3(0.1, 1.0, 0.35) / (y * 20.0);
}

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float3 color = text(fragCoord) * rain(fragCoord);

    // Desaturate / darken
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
