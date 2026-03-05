// Oily Thing
//  Converted from Shadertoy: https://www.shadertoy.com/view/fdXyRX
//  Author: pancakespeople
//  Gradient Noise by Inigo Quilez - iq/2013

Texture2D iChannel0 : register(t0);
SamplerState samp0 : register(s0);

float2 random2(float2 st) {
    st = float2(dot(st, float2(127.1, 311.7)),
                dot(st, float2(269.5, 183.3)));
    return -1.0 + 2.0 * frac(sin(st) * 43758.5453123);
}

float noise(float2 st) {
    float2 i = floor(st);
    float2 f = frac(st);

    float2 u = f * f * (3.0 - 2.0 * f);

    return lerp(lerp(dot(random2(i + float2(0.0, 0.0)), f - float2(0.0, 0.0)),
                     dot(random2(i + float2(1.0, 0.0)), f - float2(1.0, 0.0)), u.x),
                lerp(dot(random2(i + float2(0.0, 1.0)), f - float2(0.0, 1.0)),
                     dot(random2(i + float2(1.0, 1.0)), f - float2(1.0, 1.0)), u.x), u.y);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord / resolution.xy;
    float calmness = 0.1;
    float waveIntensity = 0.5;

    float2 noiseCoord = uv;
    float _oS, _oC;
    sincos(time / 10.0, _oS, _oC);
    noiseCoord += float2(_oC, _oS);

    uv.x += noise(noiseCoord / calmness) * waveIntensity;
    uv.y += noise((noiseCoord + 100.0) / calmness) * waveIntensity;

    float4 col = iChannel0.Sample(samp0, uv);
    col += noise(noiseCoord);
    col *= float4(0.3, 0.6, 1.0, 1.0);

    float3 color = col.rgb;

    return AT_PostProcess(color);
}
