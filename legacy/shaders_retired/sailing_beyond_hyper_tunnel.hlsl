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

#define FAR 1e3
#define INFINITY_VAL 1e32

#define T time
#define FOV 70.0
#define FOG 0.06

#define PI 3.14159265
#define TAU (2*PI)
#define PHI (1.618033988749895)

// Synthetic beat to replace audio input
float getBeat() {
    return smoothstep(0.6, 0.9, pow(sin(time * 1.5) * 0.5 + 0.5, 4.0)) * 0.3 + 0.4;
}

float getBeatLow() {
    return smoothstep(0.5, 0.8, pow(sin(time * 0.8) * 0.5 + 0.5, 3.0)) * 0.5 + 0.5;
}

float hash12(float2 p) {
    float h = dot(p, float2(127.1, 311.7));
    return frac(sin(h) * 43758.5453123);
}

// 3d noise
float noise_3(in float3 p) {
    float3 i = floor(p);
    float3 f = frac(p);
    // Original GLSL: vec3 u = 1.-(--f)*f*f*f*-f;
    // --f means f = f - 1, then expression is 1 - (f-1)*(f)*(f)*(f)*(-f)
    // Actually: u = f*f*f*(f*(f*6-15)+10) (quintic smoothstep)
    float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);

    float2 ii = i.xy + i.z * float2(5.0, 5.0);
    float a = hash12(ii + float2(0.0, 0.0));
    float b = hash12(ii + float2(1.0, 0.0));
    float c = hash12(ii + float2(0.0, 1.0));
    float d = hash12(ii + float2(1.0, 1.0));
    float v1 = lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);

    ii += float2(5.0, 5.0);
    a = hash12(ii + float2(0.0, 0.0));
    b = hash12(ii + float2(1.0, 0.0));
    c = hash12(ii + float2(0.0, 1.0));
    d = hash12(ii + float2(1.0, 1.0));
    float v2 = lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);

    return max(lerp(v1, v2, u.z), 0.0);
}

float fbm(float3 x) {
    float r = 0.0;
    float w = 1.0, s = 1.0;
    for (int i = 0; i < 4; i++) {
        w *= 0.25;
        s *= 3.0;
        r += w * noise_3(s * x);
    }
    return r;
}

float yC(float x) {
    return cos(x * -0.134) * 1.0 * sin(x * 0.13) * 15.0 + fbm(float3(x * 0.1, 0.0, 0.0) * 55.4);
}

void pR(inout float2 p, float a) {
    p = cos(a) * p + sin(a) * float2(p.y, -p.x);
}

struct geometry {
    float dist;
    float3 hit;
    int iterations;
};

// Cylinder with infinite height
float fCylinderInf(float3 p, float r) {
    return length(p.xz) - r;
}

geometry map(float3 p) {
    p.x -= yC(p.y * 0.1) * 3.0;
    p.z += yC(p.y * 0.01) * 4.0;

    float n = pow(abs(fbm(p * 0.06)) * 12.0, 1.3);
    float s = fbm(p * 0.01 + float3(0.0, T * 0.14, 0.0)) * 128.0;

    geometry obj;
    obj.dist = 0.0;
    obj.hit = (float3)0;
    obj.iterations = 0;

    obj.dist = max(0.0, -fCylinderInf(p, s + 18.0 - n));

    p.x -= sin(p.y * 0.02) * 34.0 + cos(p.z * 0.01) * 62.0;

    obj.dist = max(obj.dist, -fCylinderInf(p, s + 28.0 + n * 2.0));

    return obj;
}

static float t_min = 10.0;
static float t_max = FAR;
static const int MAX_ITERATIONS = 100;

geometry trace(float3 o, float3 d) {
    float omega = 1.3;
    float t = t_min;
    float candidate_error = INFINITY_VAL;
    float candidate_t = t_min;
    float previousRadius = 0.0;
    float stepLength = 0.0;
    float pixelRadius = 1.0 / 1000.0;

    geometry mp = map(o);

    float functionSign = mp.dist < 0.0 ? -1.0 : 1.0;
    float minDist = FAR;

    for (int i = 0; i < MAX_ITERATIONS; ++i) {
        mp = map(d * t + o);
        mp.iterations = i;

        float signedRadius = functionSign * mp.dist;
        float radius = abs(signedRadius);
        bool sorFail = omega > 1.0 && (radius + previousRadius) < stepLength;

        if (sorFail) {
            stepLength -= omega * stepLength;
            omega = 1.0;
        } else {
            stepLength = signedRadius * omega;
        }
        previousRadius = radius;
        float error = radius / t;

        if (!sorFail && error < candidate_error) {
            candidate_t = t;
            candidate_error = error;
        }

        if ((!sorFail && error < pixelRadius) || t > t_max) break;

        t += stepLength * 0.5;
    }

    mp.dist = candidate_t;

    if (t > t_max || candidate_error > pixelRadius)
        mp.dist = INFINITY_VAL;

    return mp;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 ouv = fragCoord.xy / resolution.xy;
    float2 uv = ouv - 0.5;

    uv *= tan(radians(FOV) / 2.0) * 4.0;

    float3 vuv = normalize(float3(cos(T), sin(T * 0.11), sin(T * 0.41))); // up
    float3 ro = float3(0.0, 30.0 + time * 100.0, -0.1);

    ro.x += yC(ro.y * 0.1) * 3.0;
    ro.z -= yC(ro.y * 0.01) * 4.0;

    float3 vrp = float3(0.0, 50.0 + time * 100.0, 2.0);

    vrp.x += yC(vrp.y * 0.1) * 3.0;
    vrp.z -= yC(vrp.y * 0.01) * 4.0;

    float3 vpn = normalize(vrp - ro);
    float3 u = normalize(cross(vuv, vpn));
    float3 v = cross(vpn, u);
    float3 vcv = ro + vpn;
    float3 scrCoord = vcv + uv.x * u * resolution.x / resolution.y + uv.y * v;
    float3 rd = normalize(scrCoord - ro);
    float3 oro = ro;

    float3 sceneColor = (float3)0;

    geometry tr = trace(ro, rd);

    tr.hit = ro + rd * tr.dist;

    float3 col = float3(1.0, 0.5, 0.4) * fbm(tr.hit.xzy * 0.01) * 20.0;
    col.b *= fbm(tr.hit * 0.01) * 10.0;

    sceneColor += min(0.8, (float)tr.iterations / 90.0) * col + col * 0.03;
    sceneColor *= 1.0 + 0.9 * (abs(fbm(tr.hit * 0.002 + 3.0) * 10.0) * (fbm(float3(0.0, 0.0, time * 0.05) * 2.0)) * 1.0);
    // Replace audio: texelFetch(iChannel0, ivec2(128, 0), 0).r with synthetic beat
    sceneColor = pow(sceneColor, (float3)1.0) * getBeat() * min(1.0, time * 0.1);

    float3 steamColor1 = float3(0.0, 0.4, 0.5);
    float3 rro = oro;

    ro = tr.hit;

    float distC = tr.dist;
    float f = 0.0;
    float st = 0.9;

    for (float i = 0.0; i < 24.0; i++) {
        rro = ro - rd * distC;
        f += fbm(rro * float3(0.1, 0.1, 0.1) * 0.3) * 0.1;
        distC -= 3.0;
        if (distC < 3.0) break;
    }

    // Replace audio: texelFetch(iChannel0, ivec2(32, 0), 0).r with synthetic low beat
    steamColor1 *= getBeatLow();
    sceneColor += steamColor1 * pow(abs(f * 1.5), 3.0) * 4.0;

    float4 fragColor = float4(clamp(sceneColor * (1.0 - length(uv) / 2.0), 0.0, 1.0), 1.0);
    fragColor = pow(abs(fragColor / tr.dist * 130.0), (float4)0.8);

    // Post-processing: darken/desaturate
    float3 color = fragColor.rgb;
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
