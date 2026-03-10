// 80's style screen saver with simple lines
// Original: https://www.shadertoy.com/view/dsKfRz by bschu
// Line function by gPlati: https://www.shadertoy.com/view/MlcGDB

float lineSDF(float2 P, float2 A, float2 B, float r) {
    float2 g = B - A;
    float d = abs(dot(normalize(float2(g.y, -g.x)), P - A));
    return smoothstep(r, 0.5 * r, d);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord / resolution.xy;

    // A fancy changing color
    float _sh, _ch;
    sincos(time * 0.5, _sh, _ch);
    float r = abs(_sh);
    float g = abs(cos(time * 0.333333));
    float b = abs(sin(time * 0.25));

    float3 changing = float3(r, g, b);
    float3 color = (float3)(abs(_ch) - 0.8);

    // Points for our lines
    float speed = 0.3;
    float _ss, _cs;
    sincos(time * speed, _ss, _cs);
    float x1 = _ss;
    float x2 = _cs;

    float l = 0.0;
    float amount = 100.0;
    float width = 0.005;

    for (float i = -amount; i < amount; i += 1.0) {
        float start = i * 0.05;
        l = lineSDF(uv, float2(x1 + start, x1 - start), float2(x2 + start, x2), width);
        color = (1.0 - l) * color + (l * changing);
    }

    return AT_PostProcess(color);
}
