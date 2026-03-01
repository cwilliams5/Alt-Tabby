// Bokeh Lights
//  Converted from Shadertoy: https://www.shadertoy.com/view/4lXXD2
//  Author: inferno (based on BigWIngs)
//  License: CC BY-NC-SA 3.0

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

static const float3 worldUp = float3(0., 1., 0.);
static const float twopi = 6.283185307179586;

static const int NUM_LIGHTS = 150;
static const float _FocalDistance = 0.0035;
static const float _DOF = 1.0;
static const float _ZOOM = 0.6;

struct Ray {
    float3 o;
    float3 d;
};

struct Camera {
    float3 p;
    float3 fwd;
    float3 left;
    float3 up;
    float3 lookAt;
    float zoom;
};

static Ray eyeRay;
static Camera cam;

float hash(float n) {
    return frac(sin(n) * 1751.5453);
}

float2 hash2(float n) {
    float2 n2 = float2(n, -n + 2.1323);
    return frac(sin(n2) * 1751.5453);
}

float cubicPulse(float c, float w, float x) {
    x = abs(x - c);
    if (x > w) return 0.;
    x /= w;
    return 1. - x * x * (3. - 2. * x);
}

// Direct rotation math (avoids GLSL/HLSL matrix convention issues)
float3 rotate_y(float3 v, float angle) {
    float ca = cos(angle); float sa = sin(angle);
    return float3(ca * v.x - sa * v.z, v.y, sa * v.x + ca * v.z);
}

float3 rotate_x(float3 v, float angle) {
    float ca = cos(angle); float sa = sin(angle);
    return float3(v.x, ca * v.y - sa * v.z, sa * v.y + ca * v.z);
}

float3 ClosestPoint(Ray r, float3 p) {
    return r.o + max(1., dot(p - r.o, r.d)) * r.d;
}

float hash3(float n) {
    return frac(sin(n) * 753.5453123);
}

float vnoise(float3 x) {
    float3 p = floor(x);
    float3 f = frac(x);
    f = f * f * (3.0 - 2.0 * f);

    float n = p.x + p.y * 157.0 + 113.0 * p.z;
    return lerp(lerp(lerp(hash3(n + 0.0), hash3(n + 1.0), f.x),
                     lerp(hash3(n + 157.0), hash3(n + 158.0), f.x), f.y),
                lerp(lerp(hash3(n + 113.0), hash3(n + 114.0), f.x),
                     lerp(hash3(n + 270.0), hash3(n + 271.0), f.x), f.y), f.z);
}

float Bokeh(Ray r, float3 p) {
    float dist = length(p - ClosestPoint(r, p));

    float distFromCam = length(p - eyeRay.o);
    float focus = cubicPulse(_FocalDistance, _DOF, distFromCam);

    float3 inFocus = float3(0.2, -0.1, 1.);
    float3 outFocus = float3(0.25, 0.2, 0.05);

    float3 thisFocus = lerp(outFocus, inFocus, focus);

    return smoothstep(thisFocus.x, thisFocus.y, dist) * thisFocus.z;
}

float3 Lights(Ray r, float t) {
    float3 col = (float3)0.;

    float height = 4.;
    float halfHeight = height / 2.;

    for (int i = 0; i < NUM_LIGHTS; i++) {
        float fi = (float)i;
        float c = fi / (float)NUM_LIGHTS;
        c *= twopi;

        float2 xy = hash2(fi) * 10. - 5.;
        float y = frac(c) * height - halfHeight;

        float3 pos = float3(xy.x, y, xy.y);
        pos += float3(vnoise(fi * pos * time * 0.0006), vnoise(fi * pos * time * 0.0002), 0.0);

        float glitter = 1. + clamp((sin(c + t * 3.) - 0.9) * 50., 0., 100.);

        col += Bokeh(r, pos) * glitter * lerp(float3(2.5, 2.2, 1.9), float3(0.7, 1.6, 3.0), 0.5 + 0.5 * sin(fi * 1.2 + 1.9));
    }
    return col;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = (fragCoord.xy / resolution.xy) - 0.5;
    uv.y *= resolution.y / resolution.x;

    // Gentle time-based camera sweep (replaces iMouse)
    float mx = 0.5 + sin(time * 0.05) * 0.2;
    float my = 0.5 + cos(time * 0.035) * 0.15;

    float t = time;
    float speed = 0.004;
    float st = sin(t * speed);
    float ct = cos(t * speed);

    cam.p = float3(st, st, ct) * float3(4., 3.5, 4.);
    cam.p = normalize(cam.p);

    cam.p = rotate_x(cam.p, my * 2.0 + 5.2);
    cam.p = rotate_y(cam.p, mx * 3.0);

    cam.lookAt = (float3)0.;
    cam.fwd = normalize(cam.lookAt - cam.p);
    cam.left = cross(worldUp, cam.fwd);
    cam.up = cross(cam.fwd, cam.left);
    cam.zoom = _ZOOM;

    float3 screenCenter = cam.p + cam.fwd * cam.zoom;
    float3 screenPoint = screenCenter + cam.left * uv.x + cam.up * uv.y;

    eyeRay.o = cam.p;
    eyeRay.d = normalize(screenPoint - cam.p);

    float3 col = (float3)0.;
    col += Lights(eyeRay, t * 0.2);
    col += 0.05;

    // Darken/desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, (float3)lum, desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}
