// Fire and Water — converted from Shadertoy XctBWl by zhizi
// Rotating comet effect with particle trails
// License: CC BY-NC-SA 3.0

static const float PI = 3.14159265857;
static const float speedfactor = 1.0;
static const float particlenums = 45.0;

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float unit = PI / 280.0;
    float intensityfactor = 1.0 / particlenums / 15000.0;

    float2 uv = fragCoord / resolution;
    float aspect = resolution.x / resolution.y;
    uv = (uv - float2(0.5, 0.5)) * float2(aspect, 1.0);

    float3 color = (float3)0.0;

    [loop]
    for (float i = 0.0; i < particlenums; i++) {
        float t = unit * i + time * speedfactor;
        float _st, _ct;
        sincos(t, _st, _ct);
        float2 orbit = float2(_st, _ct) * 0.35;

        float2 fuv = 1.25 * uv + orbit;
        float3 fire = float3(0.7, 0.2, 0.1) / length(fuv) * (i * i);
        color += fire;

        float2 wuv = 1.25 * uv - orbit;
        float3 water = float3(0.1, 0.2, 0.7) / length(wuv) * (i * i);
        color += water;
    }

    color = color * intensityfactor;

    return AT_PostProcess(color);
}
