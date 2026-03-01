cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};

#define iterations 17
#define formuparam 0.53

#define volsteps 20
#define stepsize 0.1

#define zoom   0.800
#define tile   0.850
#define speed  0.000

#define brightness 0.0015
#define darkmatter 0.300
#define distfading 0.730
#define saturation 0.850

float3 glsl_mod(float3 a, float3 b) {
    return a - b * floor(a / b);
}

float2 hash(float2 p)
{
    p = float2(dot(p, float2(127.1, 311.7)),
               dot(p, float2(175., 100.)));
    return -1.0 + 2.0 * frac(sin(p) * 45000.0);
}

float noise(float2 p)
{
    const float K1 = 0.36;
    const float K2 = 0.22;

    float2 i = floor(p + (p.x + p.y) * K1);

    float2 a = p - i + (i.x + i.y) * K2;
    float2 o = (a.x > a.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float2 b = a - o + K2;
    float2 c = a - 1.0 + 2.0 * K2;

    float3 h = max(0.5 - float3(dot(a, a), dot(b, b), dot(c, c)), 0.0);

    float3 n = h * h * h * h * float3(dot(a, hash(i + 0.0)), dot(b, hash(i + o)), dot(c, hash(i + 1.0)));

    return dot(n, (float3)70.0);
}

float fbm(float2 uv)
{
    float f;
    float2x2 m = float2x2(1.6, -1.2, 1.2, 1.6);
    f  = 0.5000 * noise(uv); uv = mul(m, uv);
    f += 0.2500 * noise(uv); uv = mul(m, uv);
    f += 0.1250 * noise(uv); uv = mul(m, uv);
    f += 0.0625 * noise(uv); uv = mul(m, uv);
    f = 0.5 + 0.5 * f;

    return f;
}

float field2(float3 p, float s) {
    float strength = 7. + .03 * log(1.e-6 + frac(sin(time * 10.) * 4500.0));
    float accum = s * 3.;
    float prev = 0.;
    float tw = 0.;
    for (int i = 0; i < 12; ++i) {
        float mag = dot(p, p) * s;
        p = abs(p) / mag + float3(-.9, -1.0, -1.);
        float w = exp(-(float)i / 9.);
        accum += w * exp(-strength * pow(abs(mag - prev), 2.2));
        tw += w;
        prev = mag;
    }
    return max(0., 5. * accum / tw - .8);
}

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    // get coords and direction
    float2 uv = fragCoord.xy / resolution.xy - 0.5;
    uv.y *= resolution.y / resolution.x;
    float3 dir = float3(uv * zoom, 1.);

    float3 from = float3(1., .5, 0.5);

    float2 pos = (fragCoord.xy / resolution.xy) * 2.0 - 1.0;
    pos.x *= resolution.x / resolution.y;

    float2 pos2 = pos;
    pos2.y -= time * .10;
    float4 o = (float4)0;
    float2 F = fragCoord;

    float s = fbm(pos2);

    float f = field2(float3(pos, 1.0), s / 1.275);
    float2 R = resolution.xy;

    float d, t_loop, loop_i;
    t_loop = time * .01;
    [loop]
    for (loop_i = 0.; loop_i > -1.; loop_i -= .06)
    {
        d = frac(loop_i - 3. * t_loop);
        float4 c = float4((F - R * .5) / R.y * d, loop_i, 0) * 28.;
        for (int j = 0; j < 27; j++)
            c.xzyw = abs(c / dot(c, c)
                    - float4(7. - .2 * sin(t_loop), 6.3, .7, 1. - cos(t_loop / .8)) / 7.);
        o -= c * c.yzww * d * (d - 1.0) / float4(1, 4, 1, 1);
    }

    float3 color = float3(f * 0.1, f * f * 0.2, f * f * f * 0.79 + -0.3);

    // volumetric rendering
    float s2 = 0.1, fade = 1.;
    float3 v = (float3)0.;
    for (int r = 0; r < volsteps; r++) {
        float3 p = from + s * dir * .5 + o.xyz;
        p = abs((float3)tile - glsl_mod(p, (float3)(tile * 2.))) + o.xyz;
        float pa = 0., a = 0.;
        for (int k = 0; k < iterations; k++) {
            p = abs(p) / dot(p, p) - formuparam;
            float ct = cos(time * 0.05);
            float sn = sin(time * 0.05);
            p.xy = mul(float2x2(ct, -sn, sn, ct), p.xy);
            a += abs(length(p) - pa);
            pa = length(p);
        }
        float dm = max(0., darkmatter - a * a * .001);
        a *= a * a;
        if (r > 6) fade *= 1.2 - dm * f;
        v += fade;
        v += float3(s, s * f * s, s * s * s * s) * a * brightness * fade;
        fade *= distfading;
        s += stepsize;
    }
    v = lerp((float3)length(v), v, saturation);
    float3 col = v * .01 * f;

    // darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // alpha from brightness, premultiply
    float alpha = max(col.r, max(col.g, col.b));
    return float4(col * alpha, alpha);
}
