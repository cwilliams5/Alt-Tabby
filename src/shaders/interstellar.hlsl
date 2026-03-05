// Interstellar
// Hazel Quantock (TekF)
// https://www.shadertoy.com/view/Xdl3D2
// Converted from Shadertoy GLSL to HLSL for Alt-Tabby
// License: CC0 1.0 (public domain)
// Y-axis: no flip (symmetric radial starfield)

Texture2D iChannel0 : register(t0);
SamplerState samp0 : register(s0);

#define GAMMA (2.2)

float3 ToGamma(in float3 col)
{
    return pow(col, (float3)(1.0 / GAMMA));
}

float4 Noise(in int2 x)
{
    return iChannel0.SampleLevel(samp0, ((float2)x + 0.5) / 256.0, 0);
}

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = input.pos.xy;

    float3 ray;
    ray.xy = 2.0 * (fragCoord.xy - resolution.xy * 0.5) / resolution.x;
    ray.z = 1.0;

    float offset = time * 0.5;
    float speed2 = (cos(offset) + 1.0) * 2.0;
    float speed = speed2 + 0.1;
    offset += sin(offset) * 0.96;
    offset *= 2.0;

    float3 col = (float3)0;

    float3 stp = ray / max(abs(ray.x), abs(ray.y));

    float3 pos = 2.0 * stp + 0.5;
    for (int i = 0; i < 20; i++)
    {
        float z = Noise((int2)pos.xy).x;
        z = frac(z - offset);
        float d = 50.0 * z - pos.z;
        float _wt = max(0.0, 1.0 - 8.0 * length(frac(pos.xy) - 0.5));
        float w = _wt * _wt;
        float3 c = max((float3)0, float3(1.0 - abs(d + speed2 * 0.5) / speed, 1.0 - abs(d) / speed, 1.0 - abs(d - speed2 * 0.5) / speed));
        col += 1.5 * (1.0 - z) * c * w;
        pos += stp;
    }

    float3 color = ToGamma(col);

    return AT_PostProcess(color);
}
