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

#define NUM_LAYERS              7
#define LAYER_SEPERATION_FACTOR 0.041
#define ZOOM_FACTOR_PERIOD      40.0
#define ZOOM_FACTOR_MIN         0.5
#define ZOOM_FACTOR_MAX         2.8
#define SCROLL_SPEED_AT_MIN_ZOOM 4.0
#define SCROLL_SPEED_AT_MAX_ZOOM 12.000001
#define ROTATION_MATRIX_MAX_SKEW 0.4
#define ROTATION_MATRIX_SKEW_PERIOD 7.4

#define TWO_PI                  6.283185307179586476925286766559
#define LAYER_STEP_SIZE         (1.0 / (float)NUM_LAYERS)

float Hash_From2D(float2 Vec) {
    float f = Vec.x + Vec.y * 37.0;
    return frac(sin(f) * 104003.9);
}

float OscilateSinScalar(float Min, float Max, float Period) {
    return (Max - Min) * (sin(time * TWO_PI / Period) * 0.5 + 0.5) + Min;
}

float GetInterpolant(float Min, float Max, float CurrentValue) {
    return (CurrentValue - Min) / (Max - Min);
}

float2x2 ZRotate_Skewed(float Angle) {
    float Skew = 1.0 - OscilateSinScalar(0.0, ROTATION_MATRIX_MAX_SKEW, ROTATION_MATRIX_SKEW_PERIOD);
    Angle = cos(Angle * 0.1) * cos(Angle * 0.7) * cos(Angle * 0.73) * 2.0;
    return float2x2(sin(Angle * Skew), cos(Angle), -cos(Angle * Skew), sin(Angle));
}

float4 SampleMaterial(float2 uv) {
    float t = time * 0.5;

    float Sample0 = iChannel0.Sample(samp0, uv * 0.1).b;
    Sample0 -= 0.5 + sin(t + sin(uv.x) + sin(uv.y)) * 0.7;
    Sample0 *= 1.6;
    Sample0 = abs(Sample0);
    Sample0 = 1.0 / (Sample0 * 10.0 + 1.0);

    float4 Colour = (float4)Sample0 * iChannel0.Sample(samp0, uv * 0.05);
    return Colour * iChannel1.Sample(samp1, (uv + (time * 1.3)) * 0.001735);
}

float3 PostProcessColour(float3 Colour, float2 uv) {
    Colour -= (float3)length(uv * 0.1);
    Colour += Hash_From2D(uv * time * 0.01) * 0.02;

    float Brightness = length(Colour);
    Colour = lerp(Colour, (float3)Brightness, Brightness - 0.5);

    return Colour;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 uv = fragCoord.xy / resolution.xy - 0.5;
    uv.x *= resolution.x / resolution.y;

    float3 Colour = float3(0.0, 0.0, 0.0);

    float ScaleValue = OscilateSinScalar(ZOOM_FACTOR_MIN, ZOOM_FACTOR_MAX, ZOOM_FACTOR_PERIOD);
    float ScrollInterpolant = GetInterpolant(ZOOM_FACTOR_MIN, ZOOM_FACTOR_MAX, ScaleValue);
    float ScrollValue = lerp(SCROLL_SPEED_AT_MIN_ZOOM, SCROLL_SPEED_AT_MAX_ZOOM, ScrollInterpolant);

    for (float i = 0.0; i < 1.0; i += LAYER_STEP_SIZE) {
        float2 uv2 = uv;
        uv2 = mul(uv2, ZRotate_Skewed(time * i * i * 12.0 * LAYER_SEPERATION_FACTOR));
        uv2 *= ScaleValue * (i * i + 1.0);
        uv2.xy += ScrollValue + time * 0.125;
        Colour += SampleMaterial(uv2).xyz * LAYER_STEP_SIZE * 3.5;
    }

    Colour = PostProcessColour(Colour, uv);

    // Post-processing: darken/desaturate
    float lum = dot(Colour, float3(0.299, 0.587, 0.114));
    Colour = lerp(Colour, float3(lum, lum, lum), desaturate);
    Colour = Colour * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(Colour.r, max(Colour.g, Colour.b));
    return float4(Colour * a, a);
}
