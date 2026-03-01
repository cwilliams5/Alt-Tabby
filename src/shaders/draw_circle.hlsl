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

float3 drawCircle(float2 pos, float radius, float width, float power, float4 color)
{
    float dist1 = length(pos);
    dist1 = frac((dist1 * 5.0) - frac(time));
    float dist2 = dist1 - radius;
    float intensity = pow(radius / abs(dist2), width);
    float3 col = color.rgb * intensity * power * max((0.8 - abs(dist2)), 0.0);
    return col;
}

float3 hsv2rgb(float h, float s, float v)
{
    float4 t = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(frac(float3(h, h, h) + t.xyz) * 6.0 - float3(t.w, t.w, t.w));
    return v * lerp(float3(t.x, t.x, t.x), clamp(p - float3(t.x, t.x, t.x), 0.0, 1.0), s);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    // -1.0 ~ 1.0
    float2 pos = (fragCoord.xy * 2.0 - resolution.xy) / min(resolution.x, resolution.y);

    float h = lerp(0.5, 0.65, length(pos));
    float4 color = float4(hsv2rgb(h, 1.0, 1.0), 1.0);
    float radius = 0.5;
    float width = 0.8;
    float power = 0.1;
    float3 finalColor = drawCircle(pos, radius, width, power, color);

    // Apply darken/desaturate
    float lum = dot(finalColor, float3(0.299, 0.587, 0.114));
    finalColor = lerp(finalColor, float3(lum, lum, lum), desaturate);
    finalColor = finalColor * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(finalColor.r, max(finalColor.g, finalColor.b));
    return float4(finalColor * a, a);
}
