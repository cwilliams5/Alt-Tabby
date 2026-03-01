// Tiles, Interesting Patterns
//  Converted from Shadertoy: https://www.shadertoy.com/view/mdBSRt
//  Author: Johnrobmiller

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

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float aspect_ratio = resolution.y / resolution.x;
    float2 uv = fragCoord.xy / resolution.x;
    uv -= float2(0.5, 0.5 * aspect_ratio);

    float rot = radians(-30.0 - time);
    float cr = cos(rot);
    float sr = sin(rot);
    uv = float2(cr * uv.x + sr * uv.y, -sr * uv.x + cr * uv.y);

    float2 scaled_uv = 20.0 * uv;
    float2 tile = frac(scaled_uv);
    float tile_dist = min(min(tile.x, 1.0 - tile.x), min(tile.y, 1.0 - tile.y));
    float square_dist = length(floor(scaled_uv));

    float edge = sin(time - square_dist * 20.0);
    edge = frac(edge * edge); // mod(edge*edge, 1.0) for non-negative values

    float value = lerp(tile_dist, 1.0 - tile_dist, step(1.0, edge));
    edge = pow(abs(1.0 - edge), 2.2) * 0.5;

    value = smoothstep(edge - 0.05, edge, 0.95 * value);

    value += square_dist * 0.1;
    value *= 0.6;

    float3 col = float3(pow(value, 2.0), pow(value, 1.5), pow(value, 1.2));

    // Darken/desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, (float3)lum, desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
