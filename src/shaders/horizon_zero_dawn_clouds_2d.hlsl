// Horizon Zero Dawn Clouds 2D — perlin-worley 2D cloudscapes
// https://www.shadertoy.com/view/WddSDr
// Author: piyushslayer | License: CC BY-NC-SA 3.0

cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

#define SAT(x) clamp(x, 0., 1.)

#define CLOUD_COVERAGE 0.64
#define CLOUD_DETAIL_COVERAGE .16
#define CLOUD_SPEED 1.6
#define CLOUD_DETAIL_SPEED 4.8
#define CLOUD_AMBIENT .01

// Hash functions by Dave_Hoskins
float hash12(float2 p)
{
    uint2 q = uint2(int2(p)) * uint2(1597334673u, 3812015801u);
    uint n = (q.x ^ q.y) * 1597334673u;
    return float(n) * (1.0 / float(0xffffffffu));
}

float2 hash22(float2 p)
{
    uint2 q = uint2(int2(p)) * uint2(1597334673u, 3812015801u);
    q = (q.x ^ q.y) * uint2(1597334673u, 3812015801u);
    return float2(q) * (1.0 / float(0xffffffffu));
}

float remap(float x, float a, float b, float c, float d)
{
    return (((x - a) / (b - a)) * (d - c)) + c;
}

// Noise function by morgan3d
float perlinNoise(float2 x) {
    float2 i = floor(x);
    float2 f = frac(x);

    float a = hash12(i);
    float b = hash12(i + float2(1.0, 0.0));
    float c = hash12(i + float2(0.0, 1.0));
    float d = hash12(i + float2(1.0, 1.0));

    float2 u = f * f * (3.0 - 2.0 * f);
    return lerp(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

float2 curlNoise(float2 uv)
{
    float2 eps = float2(0., 1.);

    float n1, n2, a, b;
    n1 = perlinNoise(uv + eps);
    n2 = perlinNoise(uv - eps);
    a = (n1 - n2) / (2. * eps.y);

    n1 = perlinNoise(uv + eps.yx);
    n2 = perlinNoise(uv - eps.yx);
    b = (n1 - n2) / (2. * eps.y);

    return float2(a, -b);
}

float worleyNoise(float2 uv, float freq, float t, bool useCurl)
{
    uv *= freq;
    uv += t + (useCurl ? curlNoise(uv * 2.) : float2(0., 0.));

    float2 id = floor(uv);
    float2 gv = frac(uv);

    float minDist = 100.;
    for (float y = -1.; y <= 1.; y += 1.)
    {
        for (float x = -1.; x <= 1.; x += 1.)
        {
            float2 offset = float2(x, y);
            float2 h = hash22(id + offset) * .8 + .1;
            h += offset;
            float2 d = gv - h;
            minDist = min(minDist, dot(d, d));
        }
    }

    return minDist;
}

float perlinFbm(float2 uv, float freq, float t)
{
    uv *= freq;
    uv += t;
    float amp = .5;
    float n = 0.;
    for (int i = 0; i < 8; ++i)
    {
        n += amp * perlinNoise(uv);
        uv *= 1.9;
        amp *= .55;
    }
    return n;
}

float4 worleyFbm(float2 uv, float freq, float t, bool useCurl)
{
    float worley0 = 0.;
    if (freq < 4.)
        worley0 = 1. - worleyNoise(uv, freq * 1., t * 1., false);
    float worley1 = 1. - worleyNoise(uv, freq * 2., t * 2., useCurl);
    float worley2 = 1. - worleyNoise(uv, freq * 4., t * 4., useCurl);
    float worley3 = 1. - worleyNoise(uv, freq * 8., t * 8., useCurl);
    float worley4 = 1. - worleyNoise(uv, freq * 16., t * 16., useCurl);

    float fbm0 = (freq > 4. ? 0. : worley0 * .625 + worley1 * .25 + worley2 * .125);
    float fbm1 = worley1 * .625 + worley2 * .25 + worley3 * .125;
    float fbm2 = worley2 * .625 + worley3 * .25 + worley4 * .125;
    float fbm3 = worley3 * .75 + worley4 * .25;
    return float4(fbm0, fbm1, fbm2, fbm3);
}

float clouds(float2 uv, float t)
{
    float coverage = hash12(float2(uv.x * resolution.y / resolution.x, uv.y)) *
        .1 + ((SAT(CLOUD_COVERAGE) * 1.6) * .5 + .5);
    float pfbm = perlinFbm(uv, 2., t);
    float4 wfbmLowFreq = worleyFbm(uv, 1.6, t * CLOUD_SPEED, false);
    float4 wfbmHighFreq = worleyFbm(uv, 8., t * CLOUD_DETAIL_SPEED, true);
    float perlinWorley = remap(abs(pfbm * 2. - 1.),
                               1. - wfbmLowFreq.r, 1., 0., 1.);
    perlinWorley = remap(perlinWorley, 1. - coverage, 1., 0., 1.) * coverage;
    float worleyLowFreq = wfbmLowFreq.g * .625 + wfbmLowFreq.b * .25
        + wfbmLowFreq.a * .125;
    float worleyHighFreq = wfbmHighFreq.g * .625 + wfbmHighFreq.b * .25
        + wfbmHighFreq.a * .125;
    float c = remap(perlinWorley, (worleyLowFreq - 1.) * .64, 1., 0., 1.);
    c = remap(c, worleyHighFreq * CLOUD_DETAIL_COVERAGE, 1., 0., 1.);
    return max(0., c);
}

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    float2 uv = fragCoord / resolution.y;

    // Sun position: slow orbit in upper portion of screen
    float aspect = resolution.x / resolution.y;
    float2 m = float2(
        aspect * 0.5 + sin(time * 0.05) * aspect * 0.35,
        0.6 + cos(time * 0.07) * 0.15);

    float t = fmod(time + 600., 7200.) * .03;

    // 2D ray march variables
    float2 marchDist = float2(.35 * max(resolution.x, resolution.y), .35 * max(resolution.x, resolution.y)) / resolution;
    float steps = 10.;
    float stepsInv = 1. / steps;
    float2 sunDir = normalize(m - uv) * marchDist * stepsInv;
    float2 marchUv = uv;
    float cloudColor = 1.;
    float cloudShape = clouds(uv, t);

    // 2D ray march lighting loop
    for (float i = 0.; i < marchDist.x; i += marchDist.x * stepsInv)
    {
        marchUv += sunDir * i;
        float c = clouds(marchUv, t);
        cloudColor *= clamp(1. - c, 0., 1.);
    }

    cloudColor += CLOUD_AMBIENT;
    // beer's law + powder sugar
    cloudColor = exp(-cloudColor) * (1. - exp(-cloudColor * 2.)) * 2.;
    cloudColor *= cloudShape;

    float3 skyCol = lerp(float3(.1, .5, .9), float3(.1, .1, .9), uv.y);
    float3 col = float3(0., 0., 0.);
    col = skyCol + cloudShape;
    col = lerp(float3(cloudColor, cloudColor, cloudColor) * 25., col, 1. - cloudShape);
    float sun = .002 / pow(length(uv - m), 1.7);
    col += (1. - smoothstep(.0, .4, cloudShape)) * sun;
    col = sqrt(col);

    // darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}