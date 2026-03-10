// Converted from Shadertoy: Tileable Water Caustic by Dave_Hoskins
// https://www.shadertoy.com/view/MdlXz8
// Original water turbulence effect by joltz0r

#define TAU 6.28318530718
#define MAX_ITER 5

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float stime = time * 0.5 + 23.0;
    float2 uv = fragCoord / resolution;

    float2 p = fmod(uv * TAU, TAU) - 250.0;
    float2 i = p;
    float c = 1.0;
    float inten = 0.005;
    float2 pInten = p * inten;

    for (int n = 0; n < MAX_ITER; n++)
    {
        float t = stime * (1.0 - (3.5 / float(n + 1)));
        i = p + float2(cos(t - i.x) + sin(t + i.y), sin(t - i.y) + cos(t + i.x));
        float2 cv = pInten / float2(sin(i.x + t), cos(i.y + t));
        c += rsqrt(dot(cv, cv));
    }
    c /= float(MAX_ITER);
    c = 1.17 - pow(c, 1.4);
    float _ac = abs(c); float _ac2 = _ac*_ac; float _ac4 = _ac2*_ac2; float v = _ac4*_ac4;
    float3 colour = saturate(float3(v, v, v) + float3(0.0, 0.35, 0.5));

    float3 color = colour;

    return AT_PostProcess(color);
}
