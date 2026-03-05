// Tiles, Interesting Patterns
//  Converted from Shadertoy: https://www.shadertoy.com/view/mdBSRt
//  Author: Johnrobmiller

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float aspect_ratio = resolution.y / resolution.x;
    float2 uv = fragCoord.xy / resolution.x;
    uv -= float2(0.5, 0.5 * aspect_ratio);

    float rot = radians(-30.0 - time);
    float sr, cr;
    sincos(rot, sr, cr);
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

    float3 col = float3(value * value, value * sqrt(value), pow(value, 1.2));

    return AT_PostProcess(col);
}
