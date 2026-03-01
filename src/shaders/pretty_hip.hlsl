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

static const float PI = 3.14159265359;

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float aspect = resolution.y / resolution.x;
    float value;
    float2 uv = fragCoord.xy / resolution.x;
    uv -= float2(0.5, 0.5 * aspect);
    float rot = PI / 4.0; // radians(45.0)
    float c = cos(rot);
    float s = sin(rot);
    // mat2 m = (c, -s, s, c); uv = m * uv
    float2 rotated_uv = float2(
        uv.x * c + uv.y * (-s),
        uv.x * s + uv.y * c);
    uv = rotated_uv;
    uv += float2(0.5, 0.5 * aspect);
    uv.y += 0.5 * (1.0 - aspect);
    float2 pos = 10.0 * uv;
    float2 rep = frac(pos);
    float dist = 2.0 * min(min(rep.x, 1.0 - rep.x), min(rep.y, 1.0 - rep.y));
    float squareDist = length((floor(pos) + float2(0.5, 0.5)) - float2(5.0, 5.0));

    float edge = sin(time - squareDist * 0.5) * 0.5 + 0.5;

    edge = (time - squareDist * 0.5) * 0.5;
    edge = 2.0 * frac(edge * 0.5);
    value = frac(dist * 2.0);
    value = lerp(value, 1.0 - value, step(1.0, edge));
    edge = pow(abs(1.0 - edge), 2.0);

    value = smoothstep(edge - 0.05, edge, 0.95 * value);

    value += squareDist * 0.1;
    float3 color = lerp(float3(1.0, 1.0, 1.0), float3(0.5, 0.75, 1.0), value);

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness + premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
