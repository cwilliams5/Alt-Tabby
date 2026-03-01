// Limestone Cave - converted from Shadertoy (WXGfz3) by altunenes
// https://www.shadertoy.com/view/WXGfz3

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

// Rotation matrix from Z-depth (replaces GLSL #define M)
float2x2 getM(float pz) {
    float4 cv = cos(pz * 1.1 + float4(0, 11, 33, 0));
    return float2x2(cv.x, cv.z, cv.y, cv.w);
}

float n(float2 p) {
    return sin(p.x * 3. + sin(p.y * 2.7)) * cos(p.y * 1.1 + cos(p.x * 2.3));
}

float f(float3 p) {
    float v = 0., a = 1.;
    for (int i = 0; i++ < 7; p *= 2., a /= 2.)
        v += n(p.xy + p.z / 2.) * a;
    return v;
}

float sdf(float3 p) {
    p.xy = mul(getM(p.z), p.xy);
    return (1. - length(p.xy) - f(p + time / 10.) * .3) / 5.;
}

float3 calcNormal(float3 p, float t) {
    float2 e = float2(1e-3 + t / 1e3, 0);
    return normalize(float3(
        sdf(p + e.xyy) - sdf(p - e.xyy),
        sdf(p + e.yxy) - sdf(p - e.yxy),
        sdf(p + e.yyx) - sdf(p - e.yyx)));
}

float calcAO(float3 p, float3 nor) {
    float o = 0., s = 1., h;
    for (int i = 0; i++ < 5; s *= .9) {
        h = .01 + .03 * float(i);
        o += (h - sdf(p + h * nor)) * s;
        if (o > .33) break;
    }
    return max(1. - 3. * o, 0.);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    float3 d = normalize(float3(fragCoord - .5 * resolution, resolution.y)),
           o = float3(0, 0, time), p, nor, l, h, c = (float3)0;
    float t = 0., w;
    for (int i = 0; i++ < 99;) {
        p = o + d * t;
        w = sdf(p);
        if (abs(w) < t / 1e3 || t > 20.) break;
        t += w;
    }

    if (t <= 20.) {
        nor = calcNormal(p, t);
        float3 q = p;
        q.xy = mul(getM(p.z), q.xy);
        c = lerp(float3(.1, .3, .7), float3(.8, .4, .2),
            clamp(f(q + time / 10.) + .5, 0., 1.));
        l = normalize(o + float3(0, 0, 4) - p);
        h = normalize(l + normalize(o - p));
        w = length(o + float3(0, 0, 4) - p);

        c = c * .02 +
            (c * max(dot(nor, l), 0.) +
            float3(.8, .8, .8) * pow(abs(max(dot(nor, h), 0.)), 16.) *
            smoothstep(15., 5., t))
            / (1. + w * w / 5.);

        c *= calcAO(p, nor);
    }

    c = lerp(float3(.02, 0, .05), c, 1. / exp(.15 * t));
    c = c * (2.51 * c + .03) / (c * (2.43 * c + .59) + .14);

    c = pow(abs(c), (float3)(1. / 2.2));

    // Darken / desaturate
    float lum = dot(c, float3(0.299, 0.587, 0.114));
    c = lerp(c, float3(lum, lum, lum), desaturate);
    c = c * (1.0 - darken);

    // Premultiplied alpha from brightness
    float a = max(c.r, max(c.g, c.b));
    return float4(c * a, a);
}
