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

float distanceToLine(float2 s, float2 p, float2 q)
{
    return abs((q.y - p.y) * s.x - (q.x - p.x) * s.y
        + q.x * p.y - q.y * p.x) / distance(p, q);
}

float triangleFn(float2 pos, float t, float val, float stp)
{
    float t1 = t * 0.523;
    float t2 = t * 0.645;
    float t3 = t * 0.779;

    float2 p1 = 0.5 + 0.5 * float2(cos(t1      ), sin(t2      ));
    float2 p2 = 0.5 + 0.5 * float2(cos(t2 + 1.0), sin(t3 + 1.0));
    float2 p3 = 0.5 + 0.5 * float2(cos(t3 + 2.0), sin(t1 + 2.0));

    float d = distanceToLine(pos, p1, p2);
    val += d < 0.01 ? stp : 0.0;

    d = distanceToLine(pos, p2, p3);
    val += d < 0.01 ? stp : 0.0;

    d = distanceToLine(pos, p3, p1);
    val += d < 0.01 ? stp : 0.0;

    return val;
}

static const float3 Red     = float3(1.0, 0.0, 0.0);
static const float3 Yellow  = float3(1.0, 1.0, 0.0);
static const float3 Green   = float3(0.0, 1.0, 0.0);
static const float3 Cyan    = float3(0.0, 1.0, 1.0);
static const float3 Blue    = float3(0.0, 0.0, 1.0);
static const float3 Magenta = float3(1.0, 0.0, 1.0);

float3 hue(float t)
{
    float f = 1.0 / 6.0;

    if (t < f)
    {
        return lerp(Red, Yellow, t / f);
    }
    else if (t < 2.0 * f)
    {
        return lerp(Yellow, Green, (t - f) / f);
    }
    else if (t < 3.0 * f)
    {
        return lerp(Green, Cyan, (t - 2.0 * f) / f);
    }
    else if (t < 4.0 * f)
    {
        return lerp(Cyan, Blue, (t - 3.0 * f) / f);
    }
    else if (t < 5.0 * f)
    {
        return lerp(Blue, Magenta, (t - 4.0 * f) / f);
    }
    else
    {
        return lerp(Magenta, Red, (t - 5.0 * f) / f);
    }
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 pos = (fragCoord - 0.5 * resolution) / resolution.y + 0.5;

    float val = 0.0;

    for (float i = 0.0; i < 10.0; i++)
    {
        val += triangleFn(pos, time + i * 0.05, val, 0.01 * i / 10.0);
    }

    val = min(1.0, val);
    val = 1.0 - (1.0 - val) * (1.0 - val);

    float3 col = val * hue(0.5 + 0.5 * sin(time + val));

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
