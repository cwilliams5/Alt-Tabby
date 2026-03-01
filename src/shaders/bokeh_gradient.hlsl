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

static const float animationProgress = 1.0;
static const float bloomIntensity = 2.1;
static const float baseCircleSize = 0.3;
static const float3 primaryColor = float3(0.2, 0.2, 0.9);
static const float3 secondaryColor = float3(0.8, 0.4, 0.9);
static const float3 accentColor = float3(0.4, 0.9, 0.6);

static const float overlayAlpha = 0.5;
static const float circleOpacity = 0.4;
static const float softness = 0.2;
static const float moveSpeed = 0.6;
static const float sizeVariation = 0.5;

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    // Shader already flips Y internally
    float2 flippedCoord = float2(fragCoord.x, resolution.y - fragCoord.y);
    float2 uv = flippedCoord / resolution.xy;

    float effectStrength = smoothstep(0.0, 1.0, animationProgress);

    float t = time * moveSpeed;

    // Circle 1
    float2 pos1 = float2(0.3, 0.4) + float2(sin(t) * 0.08, cos(t * 1.2) * 0.06) * effectStrength;
    float radius1 = baseCircleSize * (1.2 + sin(t * 2.1) * sizeVariation) * effectStrength;
    float dist1 = distance(uv, pos1);
    float circle1 = 1.0 - smoothstep(radius1 - softness, radius1 + softness, dist1);

    // Circle 2
    float2 pos2 = float2(0.7, 0.6) + float2(cos(t + 1.0) * 0.07, sin(t * 0.8 + 2.0) * 0.09) * effectStrength;
    float radius2 = baseCircleSize * (0.9 + cos(t * 1.8 + 1.5) * sizeVariation) * effectStrength;
    float dist2 = distance(uv, pos2);
    float circle2 = 1.0 - smoothstep(radius2 - softness, radius2 + softness, dist2);

    // Circle 3
    float2 pos3 = float2(0.5, 0.3) + float2(sin(t * 1.3 + 3.0) * 0.06, cos(t + 4.0) * 0.08) * effectStrength;
    float radius3 = baseCircleSize * (1.1 + sin(t * 2.5 + 2.0) * sizeVariation) * effectStrength;
    float dist3 = distance(uv, pos3);
    float circle3 = 1.0 - smoothstep(radius3 - softness, radius3 + softness, dist3);

    // Circle 4
    float2 pos4 = float2(0.2, 0.7) + float2(cos(t * 0.9 + 5.0) * 0.09, sin(t * 1.1 + 1.0) * 0.05) * effectStrength;
    float radius4 = baseCircleSize * (1.0 + cos(t * 1.9 + 3.5) * sizeVariation) * effectStrength;
    float dist4 = distance(uv, pos4);
    float circle4 = 1.0 - smoothstep(radius4 - softness, radius4 + softness, dist4);

    // Circle 5
    float2 pos5 = float2(0.8, 0.2) + float2(sin(t * 1.4 + 2.5) * 0.07, cos(t * 0.7 + 3.5) * 0.06) * effectStrength;
    float radius5 = baseCircleSize * (0.8 + sin(t * 2.2 + 4.0) * sizeVariation) * effectStrength;
    float dist5 = distance(uv, pos5);
    float circle5 = 1.0 - smoothstep(radius5 - softness, radius5 + softness, dist5);

    // Circle 6
    float2 pos6 = float2(0.6, 0.8) + float2(cos(t * 1.6 + 4.5) * 0.08, sin(t * 0.6 + 2.5) * 0.07) * effectStrength;
    float radius6 = baseCircleSize * (1.3 + cos(t * 1.7 + 5.0) * sizeVariation) * effectStrength;
    float dist6 = distance(uv, pos6);
    float circle6 = 1.0 - smoothstep(radius6 - softness, radius6 + softness, dist6);

    // Circle 7
    float2 pos7 = float2(0.4, 0.6) + float2(sin(t * 0.8 + 6.0) * 0.05, cos(t * 1.5 + 1.5) * 0.09) * effectStrength;
    float radius7 = baseCircleSize * (1.1 + sin(t * 2.8 + 1.0) * sizeVariation) * effectStrength;
    float dist7 = distance(uv, pos7);
    float circle7 = 1.0 - smoothstep(radius7 - softness, radius7 + softness, dist7);

    // Circle 8
    float2 pos8 = float2(0.1, 0.5) + float2(cos(t * 1.2 + 3.5) * 0.06, sin(t * 0.9 + 4.5) * 0.08) * effectStrength;
    float radius8 = baseCircleSize * (0.9 + cos(t * 2.0 + 2.5) * sizeVariation) * effectStrength;
    float dist8 = distance(uv, pos8);
    float circle8 = 1.0 - smoothstep(radius8 - softness, radius8 + softness, dist8);

    // Color overlays per circle
    float3 overlay1 = primaryColor * circle1 * circleOpacity;
    float3 overlay2 = secondaryColor * circle2 * circleOpacity * 0.9;
    float3 overlay3 = accentColor * circle3 * circleOpacity * 0.8;
    float3 overlay4 = primaryColor * circle4 * circleOpacity * 0.7;
    float3 overlay5 = secondaryColor * circle5 * circleOpacity * 0.8;
    float3 overlay6 = accentColor * circle6 * circleOpacity * 0.6;
    float3 overlay7 = primaryColor * circle7 * circleOpacity * 0.7;
    float3 overlay8 = secondaryColor * circle8 * circleOpacity * 0.5;

    float3 totalOverlay = overlay1 + overlay2 + overlay3 + overlay4 + overlay5 + overlay6 + overlay7 + overlay8;

    // Bloom
    float3 bloomColor = (float3)0.0;

    float bloom1 = circle1 * 0.5;
    bloomColor += primaryColor * bloom1 * (1.0 - smoothstep(0.0, radius1 + 0.05, dist1));

    float bloom3 = circle3 * 0.4;
    bloomColor += accentColor * bloom3 * (1.0 - smoothstep(0.0, radius3 + 0.05, dist3));

    float bloom5 = circle5 * 0.3;
    bloomColor += secondaryColor * bloom5 * (1.0 - smoothstep(0.0, radius5 + 0.05, dist5));

    bloomColor *= bloomIntensity * 0.3;

    // Total alpha
    float totalAlpha = (circle1 + circle2 + circle3 + circle4 + circle5 + circle6 + circle7 + circle8) * circleOpacity * overlayAlpha * effectStrength;
    totalAlpha = saturate(totalAlpha);

    float3 color = totalOverlay + bloomColor;

    // Saturation boost
    float luminance = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(float3(luminance, luminance, luminance), color, 1.2);

    // Vignette on alpha
    float2 center = float2(0.5, 0.5);
    float vignette = 1.0 - pow(distance(uv, center) * 0.9, 1.2);
    vignette = clamp(vignette, 0.6, 1.0);
    totalAlpha *= vignette;

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Premultiply with shader's own alpha
    return float4(color * totalAlpha, totalAlpha);
}