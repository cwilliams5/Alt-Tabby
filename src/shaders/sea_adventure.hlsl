// Credits to TDM https://www.shadertoy.com/view/Ms2SD1

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

// Per-pixel mutable state (reset each pixel invocation)
static float g_fire = 0.;
static float g_moonlight = 0.;
static bool g_isGhost = true;
static bool g_isWater = true;
static float g_at = 0.;
static float g_at1 = 0.;
static const float3 g_lpos = float3(0, 200, 200);

float smin(float a, float b, float h)
{
    float k = clamp((a - b) / h * .5 + .5, 0., 1.);
    return lerp(a, b, k) - k * (1. - k) * h;
}

float2x2 rot(float a)
{
    float c = cos(a), s = sin(a);
    return float2x2(c, -s, s, c);
}

float box(float3 p, float3 s)
{
    p = abs(p) - s;
    return max(p.x, max(p.y, p.z));
}

float repeatF(float p, float s)
{
    return (frac(p / s - .5) - .5) * s;
}

float2 repeatF2(float2 p, float2 s)
{
    return (frac(p / s - .5) - .5) * s;
}

float3 repeatF3(float3 p, float3 s)
{
    return (frac(p / s - .5) - .5) * s;
}

float3 kifs(float3 p, float t)
{
    p.xz = repeatF2(p.xz, (float2)10.);
    p.xz = abs(p.xz);

    float2 s = float2(10, 7) * 0.7;
    for (float i = 0.; i < 5.; ++i)
    {
        p.xz = mul(p.xz, rot(t));
        p.xz = abs(p.xz) - s;
        p.y -= 0.1 * abs(p.z);
        s *= float2(0.68, 0.55);
    }

    return p;
}

float3 kifs3d(float3 p, float t)
{
    p.xz = repeatF2(p.xz, (float2)32.);
    p = abs(p);

    float2 s = float2(10, 7) * 0.6;
    for (float i = 0.; i < 5.; ++i)
    {
        p.yz = mul(p.yz, rot(t * .7));
        p.xz = mul(p.xz, rot(t));
        p.xz = abs(p.xz) - s;
        p.y -= 0.1 * abs(p.z);
        s *= float2(0.68, 0.55);
    }

    return p;
}

float3 tunnel(float3 p)
{
    float3 off = (float3)0;
    float dd = p.z * 0.02;
    dd = floor(dd) + smoothstep(0., 1., smoothstep(0., 1., frac(dd)));
    dd *= 1.7;
    off.x += sin(dd) * 10.;
    return off;
}

float solid(float3 p)
{
    float t = time * .2;
    float3 pp = p;
    float3 p5 = p;
    pp += tunnel(p);

    float path = abs(pp.x) - 1.;

    float3 p2 = kifs(p, 0.5);
    float3 p3 = kifs(p + float3(1, 0, 0), 1.9);

    float d5 = -1.;
    p5.xy = mul(p5.xy, rot(2.8));
    p5.xz = mul(p5.xz, rot(0.5));

    float trk = 1.;
    float z = 1.;
    int iterations = 10;
    for (int i = 0; i < iterations; ++i)
    {
        p5 += sin(p5.zxy * 0.75 * trk + t * trk * .8);
        d5 -= abs(dot(cos(p5), sin(p5.yzx)) * z);
        trk *= 1.6;
        z *= 0.4;
        p5.y += t * 3.;
    }

    float d;
    float b1 = box(p2, float3(1, 1, 0.5));
    float b2 = box(p3, float3(0.5, 1.3, 1));

    float m1 = max(abs(b1), abs(b2)) - 0.2;
    d = m1;
    d = max(d, -path);
    d5 = abs(d5);
    d += sin(time * 0.1) * .3 + .5;
    if (p5.y - t * 3. * float(iterations) > -10.)
    {
        d = smin(d, d5, 3.);
    }

    g_fire += 0.2 / (0.1 + abs(d));
    return d;
}

float ghost(float3 p)
{
    float3 p2 = kifs3d(p - float3(0, 2, 3), 0.8 + time * 0.1);
    float3 p3 = kifs3d(p - float3(3, 0, 0), 1.2 + time * 0.07);

    float b1 = box(p2, (float3)5);
    float b2 = box(p3, (float3)3);

    float m1 = max(abs(b1), abs(b2)) - .2;
    float d = abs(m1) - 0.02;
    return d;
}

float hash2(float2 p) {
    float h = dot(p, float2(127.1, 311.7));
    return frac(sin(h) * 43758.5453123);
}

float noise2(float2 p) {
    float2 i = floor(p);
    float2 f = frac(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return -1.0 + 2.0 * lerp(lerp(hash2(i + float2(0, 0)),
                     hash2(i + float2(1, 0)), u.x),
                lerp(hash2(i + float2(0, 1)),
                     hash2(i + float2(1, 1)), u.x), u.y);
}

float noise3(float3 p) {
    float3 ip = floor(p);
    p = frac(p);
    p = smoothstep(0.0, 1.0, p);
    float3 st = float3(7, 137, 235);
    float4 val = dot(ip, st) + float4(0, st.y, st.z, st.y + st.z);
    float4 v = lerp(frac(sin(val) * 5672.655), frac(sin(val + st.x) * 5672.655), p.x);
    float2 v2 = lerp(v.xz, v.yw, p.y);
    return lerp(v2.x, v2.y, p.z);
}

float sea_octave(float2 uv, float choppy) {
    uv += noise2(uv);
    float2 wv = 1.0 - abs(sin(uv));
    float2 swv = abs(cos(uv));
    wv = lerp(wv, swv, wv);
    return pow(1.0 - pow(wv.x * wv.y, 0.65), choppy);
}

float water(float3 p)
{
    float freq = 0.16;
    float amp = 0.6;
    float choppy = 4.;
    float sea_time = 1. + time * 0.8;
    float2 uv = p.xz; uv.x *= 0.75;
    float2x2 octave_m = float2x2(1.6, 1.2, -1.2, 1.6);

    float d, h = 0.0;
    for (int i = 0; i < 5; i++) {
        d = sea_octave((uv + sea_time) * freq, choppy);
        d += sea_octave((uv - sea_time) * freq, choppy);
        h += d * amp;
        uv = mul(uv, octave_m); freq *= 1.9; amp *= 0.22;
        choppy = lerp(choppy, 1.0, 0.2);
    }
    return p.y - h + 1.;
}

float mapScene(float3 p)
{
    float sol = solid(p);
    float wat = water(p);
    float gho = ghost(p);
    float d = smin(sol, wat, 0.1);
    g_isWater = wat < sol;
    g_isGhost = gho < d;
    g_at += 0.1 / (0.1 + abs(gho));
    g_at1 += 0.01 / (0.1 + abs(gho));
    g_at -= g_at1;
    g_at = (g_at + abs(g_at)) / 2.;

    // moon
    float d1 = length(p - g_lpos) - 30.;
    g_moonlight += 0.5 / (0.5 + (d1 + abs(d1)));
    d = min(d, d1);

    d *= 0.7;
    return d;
}

float3 starsField(float2 uv)
{
    float iterations = 17.;
    float formuparam = 0.53;

    float volsteps = 20.;
    float stepsize = 0.1;

    float zoom = 0.200;
    float tile = 0.850;

    float brightness = 0.0015;
    float darkmatter_val = 0.300;
    float distfading = 0.730;
    float saturation = 0.850;

    uv = mul(uv, rot(time * 0.001));
    float3 dir = float3(uv * zoom, 1.);

    float s = 0.1, fade = 0.2;
    float3 v = (float3)0;
    for (float r = 0.; r < volsteps; r++) {
        float3 p = s * dir * .5;
        p = abs((float3)tile - fmod(p, (float3)(tile * 2.)));
        float pa = 0., a = 0.;
        for (float i = 0.; i < iterations; i++) {
            p = abs(p) / dot(p, p) - formuparam;
            a += abs(length(p) - pa);
            pa = length(p);
        }
        float dm = max(0., darkmatter_val - a * a * .001);
        a *= a * a;
        if (r > 6.) fade *= 1. - dm;
        v += fade;
        v += float3(s, s * s, s * s * s * s) * a * brightness * fade;
        fade *= distfading;
        s += stepsize;
    }
    v = lerp((float3)length(v), v, saturation);
    return v * .01;
}

float3 lin2srgb(float3 cl)
{
    float3 c_lo = 12.92 * cl;
    float3 c_hi = 1.055 * pow(cl, (float3)0.41666) - 0.055;
    float3 s = step((float3)0.0031308, cl);
    return lerp(c_lo, c_hi, s);
}

float3 getPixel(float2 coord)
{
    float2 uv = coord / resolution.xy;
    uv = uv * 2.0 - 1.0;
    uv.x *= resolution.x / resolution.y;

    float adv = (sin(time * 0.01) + 1.) * 100.;

    float3 s = float3(0, .6, 0);
    float3 t = float3(0, .6, 1);

    s.z += adv;
    t.z += adv;

    s -= tunnel(s);
    t -= tunnel(t);

    float3 cz = normalize(t - s);
    float3 cx = normalize(cross(float3(0, 1, 0), cz));
    float3 cy = normalize(cross(cz, cx));

    float fov = 1.;
    float3 r = normalize(uv.x * cx + uv.y * cy + cz * fov);

    float3 sky = (float3)0;

    float3 p = s;
    float2 off = float2(0.01, 0.);
    float3 n = (float3)0;
    float dd = 0.;
    float i = 0.;
    for (i = 0.; i < 100.; ++i)
    {
        float d = mapScene(p);
        dd += d;
        if (dd > 1000.)
        {
            sky = starsField(float2(r.x, r.y));
            break;
        }
        if (d < 0.001)
        {
            if (!g_isGhost)
            {
                if (!g_isWater) break;

                n = normalize(mapScene(p) - float3(mapScene(p - off.xyy), mapScene(p - off.yxy), mapScene(p - off.yyx)));
                r = reflect(r, n);
            }
            d = 0.01;
        }
        p += r * d;
    }

    float3 l = normalize(p - g_lpos);

    float falloff = 3.;

    float3 col = (float3)0;
    col = (float3)((dot(l, -n) * .5 + .5) * (1. / (0.01 + dd * falloff)));
    col += pow(g_at * .2, 0.5) * float3(1, 0, 0);
    col += pow(g_at1 * .2, 1.) * float3(0, 153. / 255., 153. / 255.);
    col += pow(g_moonlight * 2., 2.);
    col += pow(g_fire * 0.01, 2.) * float3(1, 0, 0);
    col += sky;

    return col;
}

float hash3(float3 p) {
    float h = dot(p, float3(127.1, 311.7, 527.53));
    return frac(sin(h) * 43758.5453123);
}

float4 PSMain(PSInput input) : SV_Target
{
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    // Reset per-pixel state
    g_fire = 0.;
    g_moonlight = 0.;
    g_isGhost = true;
    g_isWater = true;
    g_at = 0.;
    g_at1 = 0.;

    float3 col = getPixel(fragCoord);

    col = pow(col, (float3)2.2);
    col = lin2srgb(col);

    // Post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
