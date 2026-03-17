float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float2 uv = (2.0 * fragCoord - resolution.xy) / min(resolution.x, resolution.y);

    for (float i = 1.0; i < 8.0; i++) {
        uv.y += 0.1 *
            sin(uv.x * i * i + time * 0.5) * sin(uv.y * i * i + time * 0.5);
    }

    float3 col;
    col.r = uv.y - 0.1;
    col.g = uv.y + 0.3;
    col.b = uv.y + 0.95;

    return AT_PostProcess(col);
}
