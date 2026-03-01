// Bokeh Expe 03 — converted from Shadertoy tl3BWs
// By YitingLiu, based on BigWings bokeh tutorial
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

#define S(x, y, t) smoothstep(x, y, t)

struct ray {
    float3 o, d;
};

ray GetRay(float2 uv, float3 camPos, float3 lookat, float zoom) {
    ray a;
    a.o = camPos;

    float3 f = normalize(lookat - camPos);
    float3 r = cross(float3(0, 1, 0), f);
    float3 u = cross(f, r);
    float3 c = a.o + f * zoom;
    float3 i = c + uv.x * r + uv.y * u;
    a.d = normalize(i - a.o);

    return a;
}

float4 N14(float t) {
    return frac(sin(t * float4(123., 1024., 3456., 9575.)) * float4(2348., 125., 2518., 6578.));
}

float N(float t) {
    return frac(sin(t * 1258.) * 6527.);
}

float3 ClosetPoint(ray r, float3 p) {
    return r.o + max(0., dot(p - r.o, r.d)) * r.d;
}

float DistRay(ray r, float3 p) {
    return length(p - ClosetPoint(r, p));
}

float Bokeh(ray r, float3 p, float size, float blur) {
    size *= length(p);
    float d = DistRay(r, p);
    float c = S(size, size * (1. - blur), d);
    c *= lerp(.6, 1., S(size * .8, size, d));
    return c;
}

float3 Streetlights(ray r, float t) {
    float side = step(r.d.x, 0.);
    r.d.x = abs(r.d.x) - .08;

    float m = 0.;

    [loop] for (int si = 0; si < 10; si++) {
        float i = si * 0.1;
        float ti = frac(t + i + side * 0.1 * .5);
        float3 p = float3(2., 2., 100. - ti * 100.);
        m += Bokeh(r, p, .1, .1) * ti * ti * ti * ti;
    }
    return float3(1., .7, .3) * m;
}

float3 Envlights(ray r, float t) {
    float side = step(r.d.x, 0.);
    r.d.x = abs(r.d.x) - .08;

    float3 c = (float3)0;

    [loop] for (int ei = 0; ei < 10; ei++) {
        float i = ei * 0.1;
        float ti = frac(t + i + side * 0.1 * .5);

        float4 n = N14(i + side * 100.);

        float fade = ti * ti * ti * ti;
        float occlusion = sin(ti * 6.28 * 10. * n.x) * .5 + .5;
        fade = occlusion;

        float x = lerp(2.5, 10., n.x);
        float y = lerp(.1, 1.5, n.y);

        float3 p = float3(x, y, 50. - ti * 50.);
        float3 col = n.wzy;
        c += Bokeh(r, p, .1, .1) * fade * col * .2;
    }
    return c;
}

float3 Headlights(ray r, float t) {
    t *= .5;

    float w1 = .35;
    float w2 = w1 * 1.2;

    float m = 0.;

    [loop] for (int hi = 0; hi < 30; hi++) {
        float i = hi / 30.;

        float n = N(i);
        if (n > .1) continue;

        float ti = frac(t + i);
        float z = 100. - ti * 100.;
        float fade = ti * ti * ti * ti;

        float focus = S(.8, 1., ti);
        float size = lerp(.05, .03, focus);

        m += Bokeh(r, float3(-1. - w1, .15, z), size, .1) * fade;
        m += Bokeh(r, float3(-1. + w1, .15, z), size, .1) * fade;

        m += Bokeh(r, float3(-1. - w2, .15, z), size, .1) * fade;
        m += Bokeh(r, float3(-1. + w2, .15, z), size, .1) * fade;

        float ref = 0.;
        ref += Bokeh(r, float3(-1. - w2, -.15, z), size * 3., 1.) * fade;
        ref += Bokeh(r, float3(-1. + w2, -.15, z), size * 3., 1.) * fade;

        m += ref * focus;
    }

    return float3(.9, .9, 1.) * m;
}

float3 Taillights(ray r, float t) {
    t *= .8;

    float w1 = .25;
    float w2 = w1 * 1.2;

    float m = 0.;

    [loop] for (int ti_idx = 0; ti_idx < 15; ti_idx++) {
        float i = ti_idx / 15.;

        float n = N(i);
        if (n > .1) continue;

        float lane = step(.5, n);

        float ti = frac(t + i);
        float z = 100. - ti * 100.;
        float fade = ti * ti * ti * ti * ti;

        float focus = S(.9, 1., ti);
        float size = lerp(.05, .03, focus);

        float laneShift = S(.99, .96, ti);
        float x = 1.5 - lane * laneShift;

        float blink = step(0., sin(t * 10000.)) * 7. * lane * step(.96, ti);

        m += Bokeh(r, float3(x - w1, .15, z), size, .1) * fade;
        m += Bokeh(r, float3(x + w1, .15, z), size, .1) * fade;

        m += Bokeh(r, float3(x - w2, .15, z), size, .1) * fade;
        m += Bokeh(r, float3(x + w2, .15, z), size, .1) * fade * (1. + blink);

        float ref = 0.;
        ref += Bokeh(r, float3(x - w2, -.15, z), size * 3., 1.) * fade;
        ref += Bokeh(r, float3(x + w2, -.15, z), size * 3., 1.) * fade * (1. + blink * .1);

        m += ref * focus;
    }

    return float3(1., .1, .03) * m;
}

float2 Rain(float2 uv, float t) {
    t *= 40.;

    float2 a = float2(3., 1.);
    float2 st = uv * a;
    st.y += t * .2;
    float2 id = floor(st);

    float n = frac(sin(id.x * 716.34) * 768.34);

    uv.y += n;
    st.y += n;

    id = floor(st);
    st = frac(st) - .5;

    t += frac(sin(id.x * 76.34 + id.y * 1453.7) * 768.35) * 6.283;

    float y = -sin(t + sin(t + sin(t) * .5)) * .43;
    float2 p1 = float2(0., y);

    float2 o1 = (st - p1) / a;
    float d = length(o1);

    float m1 = S(.07, .0, d);

    float2 o2 = frac(uv * a.x * float2(1., 2.) - .5) / float2(1., 2.);
    d = length(o2);
    float m2 = S(.3 * (.5 - st.y), .0, d) * S(-.1, .1, st.y - p1.y);

    return float2(m1 * o1 * 50. + m2 * o2 * 10.);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float2 uv = fragCoord.xy / resolution.xy;
    uv -= .5;
    uv.x *= resolution.x / resolution.y;

    // iMouse zeroed — just a time scrub offset, shader animates via time
    float t = time * .05;

    float3 camPos = float3(.5, .18, 0.);
    float3 lookat = float3(.5, .22, 1.);

    float2 rainDistort = Rain(uv * 5., t) * .5;
    rainDistort += Rain(uv * 7., t) * .5;

    // water ripple effect
    uv.x += sin(uv.y * 70.) * .005;
    uv.y += sin(uv.x * 170.) * .003;

    ray r = GetRay(uv - rainDistort * .5, camPos, lookat, 2.);

    float3 col = Streetlights(r, t);
    col += Headlights(r, t);
    col += Taillights(r, t);
    col += Envlights(r, t);

    col += (r.d.y + .25) * float3(.2, .1, .5);

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
