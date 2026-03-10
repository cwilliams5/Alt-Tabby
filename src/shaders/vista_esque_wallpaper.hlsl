// Vista-Esque wallpaper thing
// Converted from: https://www.shadertoy.com/view/mlGXRc

float3 palette(float t) {
    float3 a = float3(0.667, 0.500, 0.500);
    float3 b = float3(0.500, 0.667, 0.500);
    float3 c = float3(0.667, 0.666, 0.500);
    float3 d = float3(0.200, 0.000, 0.500);

    return a + b * cos(6.28318 * (c * t * d));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    float wave = sin(time * 2.0);

    float2 uv = fragCoord / resolution;
    float3 finalCol = (float3)0;

    for (float i = 0.0; i < 7.0; i++) {
        float d = uv.y;
        float w = uv.x;

        d = sin(d - 0.3 * 0.1 * (wave / 5.0 + 5.0)) + sin(uv.x * 2.0 + time * 0.5) / 20.0 - sin(i) / 10.0 + sin(uv.x * 4.3 + time * 1.3 * i * 0.2) / 20.0;
        d = abs(d * 0.5);
        d = 0.003 / d / 8.0 * i;

        w += sin(uv.y * 2.0 + time) / 60.0;
        w = abs(sin(w * 20.0 * i / 4.0 + time * sin(i)) / 20.0 + sin(w * 10.0 * i) / 17.0) * 30.0;
        w += uv.y * 2.4 - 1.6;
        w *= 0.333333;
        w = smoothstep(0.4, 0.7, w) / 20.0;

        float3 col = palette(uv.x + time / 3.0);

        col *= d + w;
        finalCol += col;
    }

    return AT_PostProcess(finalCol);
}
