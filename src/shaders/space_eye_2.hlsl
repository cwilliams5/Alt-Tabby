cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};

float hash_f(float n)
{
    return frac(sin(n) * 758.5453) * 2.;
}

float noise(float3 x)
{
    float3 p = floor(x);
    float3 f = frac(x);
    f = f * f * (3.0 - 2.0 * f);
    float n = p.x + p.y * 57.0 + p.z * 800.0;
    float res = lerp(lerp(lerp(hash_f(n + 0.0), hash_f(n + 1.0), f.x), lerp(hash_f(n + 57.0), hash_f(n + 58.0), f.x), f.y),
            lerp(lerp(hash_f(n + 800.0), hash_f(n + 801.0), f.x), lerp(hash_f(n + 857.0), hash_f(n + 858.0), f.x), f.y), f.z);
    return res;
}

float fbm(float3 p)
{
    float f = 0.0;
    f += 0.50000 * noise(p); p = p * 2.02 + 0.15;
    f -= 0.25000 * noise(p); p = p * 2.03 + 0.15;
    f += 0.12500 * noise(p); p = p * 2.01 + 0.15;
    f += 0.06250 * noise(p); p = p * 2.04 + 0.15;
    f -= 0.03125 * noise(p);
    return f;
}

float cloud(float3 p)
{
    p -= fbm(float3(p.x, p.y, 0.0) * 0.5) * 0.7;

    float a = 0.0;
    a -= fbm(p * 3.0) * 2.2 - 1.1;
    if (a < 0.0) a = 0.0;
    a = a * a;
    return a;
}

float2x2 rot(float th) {
    float2 a = sin(float2(1.5707963, 0) + th);
    return float2x2(a.x, -a.y, a.y, a.x);
}

float3 hash33(float3 p)
{
    static const float UIF = 2.3283064365386963e-10; // 1.0 / 0xFFFFFFFF
    static const uint3 UI3 = uint3(1597334673u, 3812015801u, 2798796415u);
    uint3 q = (uint3)((int3)p) * UI3;
    q = (q.x ^ q.y ^ q.z) * UI3;
    return (float3)q * UIF;
}

// 3D Voronoi (IQ)
float voronoi(float3 p) {
    float3 b, r, g = floor(p);
    p = frac(p);
    float d = 1.;
    for (int j = -1; j <= 1; j++)
    {
        for (int i = -1; i <= 1; i++)
        {
            b = float3(i, j, -1);
            r = b - p + hash33(g + b);
            d = min(d, dot(r, r));
            b.z = 0.0;
            r = b - p + hash33(g + b);
            d = min(d, dot(r, r));
            b.z = 1.;
            r = b - p + hash33(g + b);
            d = min(d, dot(r, r));
        }
    }
    return d;
}

// fbm layer
float noiseLayers(float3 p) {
    float3 pp = float3(0., 0., p.z + time * .09);
    float t = 0.;
    float s = 0.;
    float amp = 1.;
    for (int i = 0; i < 5; i++)
    {
        t += voronoi(p + pp) * amp;
        p *= 2.;
        pp *= 1.5;
        s += amp;
        amp *= .5;
    }
    return t / s;
}

float3 n2(float2 fragCoord)
{
    float2 uv = (fragCoord.xy - 0.5 * resolution.xy) / resolution.y;
    float dd = length(uv * uv) * .025;

    float3 rd = float3(uv.x, uv.y, 1.0);

    float rip = 0.5 + sin(length(uv) * 20.0 + time) * 0.5;
    rip = pow(rip * .38, 4.15);
    rd.z = 1.0 + rip * 1.15;
    rd = normalize(rd);
    rd.xy = mul(rot(dd + time * .0125), rd.xy);
    rd *= 2.0;

    float c = noiseLayers(rd * 1.85);
    float oc = c;
    c = max(c + dot(hash33(rd) * 2. - 1., (float3).006), 0.);
    c = pow(c * 1.55, 2.5);
    float3 col = float3(.55, 0.85, .25);
    float3 col2 = float3(1.4, 1.4, 1.4) * 5.0;
    float pulse2 = voronoi(float3(rd.xy * 1.5, time * .255));
    float pulse = pow(oc * 1.35, 4.0);
    col = lerp(col, col2, pulse * pulse2) * c;
    return col;
}

#define PI 3.14159

float vDrop(float2 uv, float t)
{
    uv.y *= 0.25;
    uv.x = uv.x * 128.0;
    float dx = frac(uv.x);
    uv.x = floor(uv.x);
    uv.y *= 0.05;
    float o = sin(uv.x * 215.4);
    float s = cos(uv.x * 33.1) * .3 + .7;
    float trail = lerp(95.0, 35.0, s);
    float yv = frac(uv.y + t * s + o) * trail;
    yv = 1.0 / yv;
    yv = smoothstep(0.0, 1.0, yv * yv);
    yv = sin(yv * PI) * (s * 5.0);
    float d2 = sin(dx * PI);
    return yv * (d2 * d2);
}

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 position = (fragCoord.xy - 0.5 * resolution.xy) / resolution.y;
    float ss = sin(length(position * 2.2) + time * 0.1) * 3.5;
    ss += 8.0;
    float2 coord = ss * position;

    coord.y *= 1.0 + (sin(time * 0.04 + coord.x * .24) * 0.3);

    coord = mul(rot(ss * 0.04 + time * 0.017), coord);
    coord *= 0.25;
    coord += fbm(sin(float3(coord * 8.0, time * 0.001))) * 0.05;
    coord += time * 0.0171;
    float q = cloud(float3(coord * 1.0, 0.222));
    coord += time * 0.0171;
    q += cloud(float3(coord * 0.6, 0.722));
    coord += time * 0.0171;
    q += cloud(float3(coord * 0.3, .722));
    coord += time * 0.1171;
    q += cloud(float3(coord * 0.1, 0.722));

    float vv1 = sin(time + ss + coord.x) * 0.3;
    float vv2 = sin(time * 0.9 + ss + coord.y) * 0.2;

    float3 col = float3(1.7 - vv2, 1.7, 1.7 + vv1) + q * float3(0.7 + vv1, 0.5, 0.3 + vv2 * 1.15);
    col = pow(col, (float3)2.2) * 0.08;

    float dd = length(col * .48) + vv1;

    float nn = 0.5 + sin(ss * 2.7 + position.x * 2.41 + time * 0.9) * 0.5;

    float3 col2 = n2(fragCoord) * 0.9;

    float2 p = (fragCoord.xy - 0.5 * resolution.xy) / resolution.y;
    float d = length(p);
    p = float2(atan2(p.x, p.y) / PI, 2.5 / d);
    float t = -time * 0.04;
    float drop = vDrop(p, t);
    drop += vDrop(p, t + 0.5);
    drop *= d;

    col2 += (col * .965);

    col = lerp(col, col2, nn);
    col = lerp(col, col * 1.075, drop);

    col += col * ((d + dd) * 0.28);
    col *= d;

    // darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // alpha from brightness, premultiply
    float alpha = max(col.r, max(col.g, col.b));
    return float4(col * alpha, alpha);
}
