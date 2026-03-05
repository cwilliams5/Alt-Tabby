float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    float2 u = (fragCoord - resolution.xy / 2.) / resolution.y;
    float i = 0, d = 0, s, t = time;
    float3 p;
    float4 o = (float4)0;

    for (; i++ < 1e2; ) {
        p = float3(u * d, d + t);
        s = .15;
        while (s < 1.) {
            p += cos(t + p.yzx * .6) * sin(p.z * .1) * .2;
            p.y += sin(t + p.x) * .03;
            p += abs(dot(sin(p * s * 24.), (float3).01)) / s;
            s *= 1.5;
        }
        s = .03 + abs(2. + p.y) * .3;
        d += s;
        o += float4(1, 2, 4, 0) / s;
    }

    u -= .35;
    o = tanh(o / 7e3 / dot(u, u));

    float3 col = o.rgb;

    return AT_PostProcess(col);
}
