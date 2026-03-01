// Fork The Drive — converted from Shadertoy McX3W7
// Original: The Drive Home by Martijn Steinrucken aka BigWings - 2017
// Fork by devesh1312
// License: CC BY-NC-SA 3.0

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

#define S(x, y, z) smoothstep(x, y, z)
#define B(a, b, edge, t) S(a-edge, a+edge, t)*S(b+edge, b-edge, t)
#define sat(x) saturate(x)

#define streetLightCol float3(1., .7, .3)
#define headLightCol float3(.8, .8, 1.)
#define tailLightCol float3(1., .1, .1)

#define HIGH_QUALITY
#define CAM_SHAKE 1.
#define LANE_BIAS .5
#define RAIN

static float3 ro, rd;

float N(float t) {
    return frac(sin(t * 10234.324) * 123423.23512);
}

float3 N31(float p) {
    float3 p3 = frac(p * float3(.1031, .11369, .13787));
    p3 += dot(p3, p3.yzx + 19.19);
    return frac(float3((p3.x + p3.y) * p3.z, (p3.x + p3.z) * p3.y, (p3.y + p3.z) * p3.x));
}

float N2(float2 p) {
    float3 p3 = frac(p.xyx * float3(443.897, 441.423, 437.195));
    p3 += dot(p3, p3.yzx + 19.19);
    return frac((p3.x + p3.y) * p3.z);
}

float DistLine(float3 ro, float3 rd, float3 p) {
    return length(cross(p - ro, rd));
}

float3 ClosestPoint(float3 ro, float3 rd, float3 p) {
    return ro + max(0., dot(p - ro, rd)) * rd;
}

float Remap(float a, float b, float c, float d, float t) {
    return ((t - a) / (b - a)) * (d - c) + c;
}

float BokehMask(float3 ro, float3 rd, float3 p, float size, float blur) {
    float d = DistLine(ro, rd, p);
    float m = S(size, size * (1. - blur), d);

    #ifdef HIGH_QUALITY
    m *= lerp(.7, 1., S(.8 * size, size, d));
    #endif

    return m;
}

float SawTooth(float t) {
    return cos(t + cos(t)) + sin(2. * t) * .2 + sin(4. * t) * .02;
}

float DeltaSawTooth(float t) {
    return 0.4 * cos(2. * t) + 0.08 * cos(4. * t) - (1. - sin(t)) * sin(t + cos(t));
}

float2 GetDrops(float2 uv, float seed, float m) {
    float t = time + m * 30.;
    float2 o = (float2)0;

    uv.y += t * .05;

    uv *= float2(10., 2.5) * 2.;
    float2 id = floor(uv);
    float3 n = N31(id.x + (id.y + seed) * 546.3524);
    float2 bd = frac(uv);

    bd -= .5;
    bd.y *= 4.;
    bd.x += (n.x - .5) * .6;

    t += n.z * 6.28;
    float slide = SawTooth(t);

    float ts = 1.5;
    float2 trailPos = float2(bd.x * ts, (frac(bd.y * ts * 2. - t * 2.) - .5) * .5);

    bd.y += slide * 2.;

    #ifdef HIGH_QUALITY
    float dropShape = bd.x * bd.x;
    dropShape *= DeltaSawTooth(t);
    bd.y += dropShape;
    #endif

    float d = length(bd);

    float trailMask = S(-.2, .2, bd.y);
    trailMask *= bd.y;
    float td = length(trailPos * max(.5, trailMask));

    float mainDrop = S(.2, .1, d);
    float dropTrail = S(.1, .02, td);

    dropTrail *= trailMask;
    o = lerp(bd * mainDrop, trailPos, dropTrail);

    return o;
}

void CameraSetup(float2 uv, float3 pos, float3 lookat, float zoom, float m) {
    ro = pos;
    float3 f = normalize(lookat - ro);
    float3 r = cross(float3(0., 1., 0.), f);
    float3 u = cross(f, r);
    float t = time;

    float2 offs = (float2)0;
    #ifdef RAIN
    float2 dropUv = uv;

    #ifdef HIGH_QUALITY
    float x = (sin(t * .1) * .5 + .5) * .5;
    x = -x * x;
    float s = sin(x);
    float c = cos(x);

    // GLSL mat2(c,-s,s,c) is column-major; HLSL float2x2 is row-major
    float2x2 rot = float2x2(c, s, -s, c);

    dropUv = mul(uv, rot);
    dropUv.x += -sin(t * .1) * .5;
    #endif

    offs = GetDrops(dropUv, 1., m);

    offs += GetDrops(dropUv * 1.4, 10., m);
    #ifdef HIGH_QUALITY
    offs += GetDrops(dropUv * 2.4, 25., m);
    #endif

    float ripple = sin(t + uv.y * 3.1415 * 30. + uv.x * 124.) * .5 + .5;
    ripple *= .005;
    offs += float2(ripple * ripple, ripple);
    #endif

    float3 center = ro + f * zoom;
    float3 i = center + (uv.x - offs.x) * r + (uv.y - offs.y) * u;

    rd = normalize(i - ro);
}

float3 HeadLights(float i, float t) {
    float z = frac(-t * 2. + i);
    float3 p = float3(-.3, .1, z * 40.);
    float d = length(p - ro);

    float size = lerp(.03, .05, S(.02, .07, z)) * d;
    float m = 0.;
    float blur = .1;
    m += BokehMask(ro, rd, p - float3(.08, 0., 0.), size, blur);
    m += BokehMask(ro, rd, p + float3(.08, 0., 0.), size, blur);

    #ifdef HIGH_QUALITY
    m += BokehMask(ro, rd, p + float3(.1, 0., 0.), size, blur);
    m += BokehMask(ro, rd, p - float3(.1, 0., 0.), size, blur);
    #endif

    float distFade = max(.01, pow(1. - z, 9.));

    blur = .8;
    size *= 2.5;
    float r = 0.;
    r += BokehMask(ro, rd, p + float3(-.09, -.2, 0.), size, blur);
    r += BokehMask(ro, rd, p + float3(.09, -.2, 0.), size, blur);
    r *= distFade * distFade;

    return headLightCol * (m + r) * distFade;
}

float3 TailLights(float i, float t) {
    t = t * 1.5 + i;

    float id = floor(t) + i;
    float3 n = N31(id);

    float laneId = S(LANE_BIAS, LANE_BIAS + .01, n.y);

    float ft = frac(t);

    float z = 3. - ft * 3.;

    laneId *= S(.2, 1.5, z);
    float lane = lerp(.6, .3, laneId);
    float3 p = float3(lane, .1, z);
    float d = length(p - ro);

    float size = .05 * d;
    float blur = .1;
    float m = BokehMask(ro, rd, p - float3(.08, 0., 0.), size, blur) +
              BokehMask(ro, rd, p + float3(.08, 0., 0.), size, blur);

    #ifdef HIGH_QUALITY
    float bs = n.z * 3.;
    float brake = S(bs, bs + .01, z);
    brake *= S(bs + .01, bs, z - .5 * n.y);

    m += (BokehMask(ro, rd, p + float3(.1, 0., 0.), size, blur) +
          BokehMask(ro, rd, p - float3(.1, 0., 0.), size, blur)) * brake;
    #endif

    float refSize = size * 2.5;
    m += BokehMask(ro, rd, p + float3(-.09, -.2, 0.), refSize, .8);
    m += BokehMask(ro, rd, p + float3(.09, -.2, 0.), refSize, .8);
    float3 col = tailLightCol * m * ft;

    float b = BokehMask(ro, rd, p + float3(.12, 0., 0.), size, blur);
    b += BokehMask(ro, rd, p + float3(.12, -.2, 0.), refSize, .8) * .2;

    float3 blinker = float3(1., .7, .2);
    blinker *= S(1.5, 1.4, z) * S(.2, .3, z);
    blinker *= sat(sin(t * 200.) * 100.);
    blinker *= laneId;
    col += blinker * b;

    return col;
}

float3 StreetLights(float i, float t) {
    float side = sign(rd.x);
    float offset = max(side, 0.) * (1. / 16.);
    float z = frac(i - t + offset);
    float3 p = float3(2. * side, 2., z * 60.);
    float d = length(p - ro);
    float blur = .1;
    float3 rp = ClosestPoint(ro, rd, p);
    float distFade = Remap(1., .7, .1, 1.5, 1. - pow(1. - z, 6.));
    distFade *= (1. - z);
    float m = BokehMask(ro, rd, p, .05 * d, blur) * distFade;

    return m * streetLightCol;
}

float3 EnvironmentLights(float i, float t) {
    float n = N(i + floor(t));

    float side = sign(rd.x);
    float offset = max(side, 0.) * (1. / 16.);
    float z = frac(i - t + offset + frac(n * 234.));
    float n2 = frac(n * 100.);
    float3 p = float3((3. + n) * side, n2 * n2 * n2 * 1., z * 60.);
    float d = length(p - ro);
    float blur = .1;
    float3 rp = ClosestPoint(ro, rd, p);
    float distFade = Remap(1., .7, .1, 1.5, 1. - pow(1. - z, 6.));
    float m = BokehMask(ro, rd, p, .05 * d, blur);
    m *= distFade * distFade * .5;

    m *= 1. - pow(sin(z * 6.28 * 20. * n) * .5 + .5, 20.);
    float3 randomCol = float3(frac(n * -34.5), frac(n * 4572.), frac(n * 1264.));
    float3 col = lerp(tailLightCol, streetLightCol, frac(n * -65.42));
    col = lerp(col, randomCol, n);
    return m * col * .2;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    float t = time * 0.2;
    float3 col = (float3)0;
    float2 uv = fragCoord.xy / resolution.xy;

    uv -= .5;
    uv.x *= resolution.x / resolution.y;

    // iMouse zeroed — shader animates via time, mouse was just a time scrub offset
    float3 pos = float3(.3, .15, 0.);

    float bt = t * 5.;
    float h1 = N(floor(bt));
    float h2 = N(floor(bt + 1.));
    float bumps = lerp(h1, h2, frac(bt)) * .1;
    bumps = bumps * bumps * bumps * CAM_SHAKE;

    pos.y += bumps;
    float lookatY = pos.y + bumps;
    float3 lookat = float3(0.3, lookatY, 1.);
    float3 lookat2 = float3(0., lookatY, .7);
    lookat = lerp(lookat, lookat2, sin(t * .1) * .5 + .5);

    uv.y += bumps * 4.;
    CameraSetup(uv, pos, lookat, 2., 0.);

    t *= .03;

    [unroll] for (int si = 0; si < 8; si++) {
        col += StreetLights(si * 0.125, t);
    }

    [unroll] for (int hi = 0; hi < 8; hi++) {
        float hf = hi * 0.125;
        float n = N(hf + floor(t));
        col += HeadLights(hf + n * 0.125 * .7, t);
    }

    #ifdef HIGH_QUALITY
    [unroll] for (int ei = 0; ei < 32; ei++) {
        col += EnvironmentLights(ei * 0.03125, t);
    }
    #else
    [unroll] for (int ei = 0; ei < 16; ei++) {
        col += EnvironmentLights(ei * 0.0625, t);
    }
    #endif

    col += TailLights(0., t);
    col += TailLights(.5, t);

    col += sat(rd.y) * float3(.6, .5, .9);

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
