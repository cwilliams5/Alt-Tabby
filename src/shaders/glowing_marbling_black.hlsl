float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = (2.0 * fragCoord - resolution) / min(resolution.x, resolution.y);

    for (float i = 1.0; i < 10.0; i++) {
        uv.x += 0.6 / i * cos(i * 2.5 * uv.y + time);
        uv.y += 0.6 / i * cos(i * 1.5 * uv.x + time);
    }

    float3 color = (float3)(0.1) / abs(sin(time - uv.y - uv.x));

    return AT_PostProcess(color);
}
