// Optical Spaghetti — converted from Shadertoy GLSL

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 u = fragCoord.xy;

    float i = 0.0;
    float a = 0.0;
    float d = 0.0;
    float s = 0.0;
    float t = time + 10.0;
    float r = 0.0;

    float3 p = float3(resolution, 1.0);
    u = (u + u - p.xy) / p.y;

    float4 o = (float4)0;

    float _sin_t02 = sin(t * 0.2);
    float _sin_t01_scale = sin(t * 0.1) * 0.25;
    for (i = 0.0; i++ < 175.0; ) {
        s = 0.004 + abs(s) * 0.1;
        d += s;

        o += s * d;
        o.r += (d * 1.5 - 5.0 / s) * 0.25;
        o.b += sin(d * 0.09 + p.z * 0.3) * 2.0 / s;
        o.g += sin(d * 0.2) / s;

        p = float3(u * d, d + t * 5.0);
        s = min(p.z, 1.9 + sin(p.z) * 0.15);

        float _inner_scale = 2.2 + _sin_t01_scale;
        for (a = 1.0; a < 2.0; a += a) {
            p += cos(t * 0.1 - p.yzx * 0.5) * 0.5;

            r = p.z * 0.1 + _sin_t02;

            float _rs, _rc;
            sincos(r, _rs, _rc);
            float2x2 rot = float2x2(_rc, -_rs, _rs, _rc);
            p.xy = mul(p.xy, rot);
            s += abs(sin(p.x * a)) * _inner_scale * -abs(sin(abs(p.y) * a) / a);
        }
    }

    o = pow(tanh(o * o / 1.5e8 * length(u)), (float4)(1.0 / 2.2));
    o *= o;

    float3 color = o.rgb;

    return AT_PostProcess(color);
}
