static const float PI = 3.14159265359;

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float aspect = resolution.y / resolution.x;
    float value;
    float2 uv = fragCoord.xy / resolution.x;
    uv -= float2(0.5, 0.5 * aspect);
    float rot = PI / 4.0; // radians(45.0)
    float s, c;
    sincos(rot, s, c);
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
    float absEdge = abs(1.0 - edge);
    edge = absEdge * absEdge;

    value = smoothstep(edge - 0.05, edge, 0.95 * value);

    value += squareDist * 0.1;
    float3 color = lerp(float3(1.0, 1.0, 1.0), float3(0.5, 0.75, 1.0), value);

    return AT_PostProcess(color);
}
