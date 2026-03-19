Texture2D iChannel0 : register(t0);
SamplerState samp0 : register(s0);

// rotate position around axis
float2 rotate(float2 p, float a)
{
    float s, c;
    sincos(a, s, c);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// 1D random numbers
float rand(float n)
{
    return frac(sin(n) * 43758.5453123);
}

// 2D random numbers
float2 rand2(float2 p)
{
    return frac(float2(sin(p.x * 591.32 + p.y * 154.077), cos(p.x * 391.32 + p.y * 49.077)));
}

// 1D noise
float noise1(float p)
{
    float fl = floor(p);
    float fc = frac(p);
    return lerp(rand(fl), rand(fl + 1.0), fc);
}

// voronoi distance noise, based on iq's articles
float voronoi(float2 x)
{
    float2 p = floor(x);
    float2 f = frac(x);

    float2 res = (float2)8.0;
    for (int j = -1; j <= 1; j++)
    {
        for (int i = -1; i <= 1; i++)
        {
            float2 b = float2(i, j);
            float2 r = b - f + rand2(p + b);

            // chebyshev distance, one of many ways to do this
            float d = max(abs(r.x), abs(r.y));

            if (d < res.x)
            {
                res.y = res.x;
                res.x = d;
            }
            else if (d < res.y)
            {
                res.y = d;
            }
        }
    }
    return res.y - res.x;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float flicker = noise1(time * 2.0) * 0.8 + 0.4;

    float2 uv = fragCoord.xy / resolution.xy;
    uv = (uv - 0.5) * 2.0;
    float2 suv = uv;
    uv.x *= resolution.x / resolution.y;

    float v = 0.0;

    // a bit of camera movement
    uv *= 0.6 + sin(time * 0.1) * 0.4;
    uv = rotate(uv, sin(time * 0.3));
    uv += time * 0.4;

    // add some noise octaves
    float a = 0.6, f = 1.0;

    for (int i = 0; i < 3; i++)
    {
        float v1 = voronoi(uv * f + 5.0);
        float v2 = 0.0;

        // make the moving electrons-effect for higher octaves
        if (i > 0)
        {
            // of course everything based on voronoi
            v2 = voronoi(uv * f * 0.5 + 50.0 + time);

            float va = smoothstep(0.1, 0.0, v1);
            float vb = smoothstep(0.08, 0.0, v2);
            float vab = va * (0.5 + vb);
            v += a * vab * vab;
        }

        // make sharp edges
        v1 = smoothstep(0.3, 0.0, v1);

        // noise is used as intensity map
        v2 = a * (noise1(v1 * 5.5 + 0.1));

        // octave 0's intensity changes a bit
        if (i == 0)
            v += v2 * flicker;
        else
            v += v2;

        f *= 3.0;
        a *= 0.7;
    }

    // slight vignetting
    v *= exp(-0.6 * length(suv)) * 1.2;

    // use texture channel0 for color
    float3 cexp = iChannel0.Sample(samp0, uv * 0.001).xyz * 3.0 + iChannel0.Sample(samp0, uv * 0.01).xyz;
    cexp *= 1.4;

    float3 col = float3(pow(v, cexp.x), pow(v, cexp.y), pow(v, cexp.z)) * 2.0;

    return AT_PostProcess(col);
}
