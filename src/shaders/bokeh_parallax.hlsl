// Bokeh Parallax — based on https://www.shadertoy.com/view/4s2yW1
// Original by knarkowicz

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

// GLSL mod: x - y * floor(x/y), differs from HLSL fmod for negatives
float glsl_mod(float x, float y) { return x - y * floor(x / y); }
float2 glsl_mod(float2 x, float y) { return x - y * floor(x / y); }

void Rotate(inout float2 p, float a)
{
    p = cos(a) * p + sin(a) * float2(p.y, -p.x);
}

float Circle(float2 p, float r)
{
    return (length(p / r) - 1.0) * r;
}

float Rand(float2 c)
{
    return frac(sin(dot(c.xy, float2(12.9898, 78.233))) * 43758.5453);
}

void BokehLayer(inout float3 color, float2 p, float3 c)
{
    float wrap = 450.0;
    if (glsl_mod(floor(p.y / wrap + 0.5), 2.0) == 0.0)
    {
        p.x += wrap * 0.5;
    }

    float2 p2 = glsl_mod(p + 0.5 * wrap, wrap) - 0.5 * wrap;
    float2 cell = floor(p / wrap + 0.5);
    float cellR = Rand(cell);

    c *= frac(cellR * 3.33 + 3.33);
    float radius = lerp(30.0, 70.0, frac(cellR * 7.77 + 7.77));
    p2.x *= lerp(0.9, 1.1, frac(cellR * 11.13 + 11.13));
    p2.y *= lerp(0.9, 1.1, frac(cellR * 17.17 + 17.17));

    float sdf = Circle(p2, radius);
    float circle = 1.0 - smoothstep(0.0, 1.0, sdf * 0.04);
    float glow = exp(-sdf * 0.025) * 0.3 * (1.0 - circle);
    color += c * (circle + glow);
}

float4 PSMain(PSInput input) : SV_Target {
    // Y-flip: background gradient has vertical direction
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    float2 uv = fragCoord.xy / resolution.xy;
    float2 p = (2.0 * fragCoord - resolution.xy) / resolution.x * 1000.0;

    // background
    float3 color = lerp(float3(0.3, 0.1, 0.3), float3(0.1, 0.4, 0.5), dot(uv, float2(0.2, 0.7)));

    float t = time - 15.0;

    Rotate(p, 0.2 + t * 0.03);
    BokehLayer(color, p + float2(-50.0 * t + 0.0, 0.0), 3.0 * float3(0.4, 0.1, 0.2));
    Rotate(p, 0.3 - t * 0.05);
    BokehLayer(color, p + float2(-70.0 * t + 33.0, -33.0), 3.5 * float3(0.6, 0.4, 0.2));
    Rotate(p, 0.5 + t * 0.07);
    BokehLayer(color, p + float2(-60.0 * t + 55.0, 55.0), 3.0 * float3(0.4, 0.3, 0.2));
    Rotate(p, 0.9 - t * 0.03);
    BokehLayer(color, p + float2(-25.0 * t + 77.0, 77.0), 3.0 * float3(0.4, 0.2, 0.1));
    Rotate(p, 0.0 + t * 0.05);
    BokehLayer(color, p + float2(-15.0 * t + 99.0, 99.0), 3.0 * float3(0.2, 0.0, 0.4));

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, (float3)lum, desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float outA = max(color.r, max(color.g, color.b));
    return float4(color * outA, outA);
}
