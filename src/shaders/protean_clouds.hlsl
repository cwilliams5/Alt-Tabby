// Protean Clouds - Volumetric cloud raymarching with swirling motion
// Original: Protean clouds by nimitz (Shadertoy 3l23Rh)
// License: CC BY-NC-SA 3.0
// Mouse input removed; camera follows automated path.

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

// --- Globals set per-frame in PSMain ---
static float prm1;
static float2 bsMo;

// --- Helpers ---

// Rotation macro: GLSL mat2(cos(a+vec4(0,11,33,0))) with v*M convention.
// GLSL column-major → HLSL row-major transposed for mul(v, M).
float2x2 rot(float a) {
    float4 c = cos(a + float4(0, 11, 33, 0));
    return float2x2(c.x, c.z, c.y, c.w);
}

float linstep(float m, float M, float x) {
    return clamp((x - m) / (M - m), 0.0, 1.0);
}

float2 disp(float t) {
    return 2.0 * float2(sin(t * 0.22), cos(t * 0.175));
}

// GLSL mat3 column-major → HLSL row-major transposed for mul(v, M).
// Original columns: (.33338,.56034,-.71817), (-.87887,.32651,-.15323), (.15162,.69596,.61339)
static const float3x3 rotM3 = float3x3(
     0.33338, -0.87887,  0.15162,
     0.56034,  0.32651,  0.69596,
    -0.71817, -0.15323,  0.61339);

// --- Volumetric map ---

float2 map(float3 p) {
    float2 q = p.xy - disp(p.z);
    p.xy = mul(p.xy, rot(sin(p.z + time) * (0.1 + prm1 * 0.05) + time * 0.09));
    float d = 0.0, z = 1.0, trk = 1.0,
          dspAmp = 0.1 + prm1 * 0.2;

    p *= 0.61;
    for (int i = 0; i < 5; i++) {
        p += dspAmp * sin(trk * (p.zxy * 0.75 + time * 0.8));
        d -= z * abs(dot(cos(p), sin(p.yzx)));
        p = mul(p, rotM3) * 1.93;
        z *= 0.57;
        trk *= 1.4;
    }

    d = abs(d + prm1 * 3.0) + prm1 * 0.3 - 2.5 + bsMo.y;
    return float2(d + 0.25, 0.0) + dot(q, q) * float2(0.2, 1.0);
}

// --- Raymarcher ---

float4 render(float3 ro, float3 rd, float animTime) {
    float4 rez = (float4)0;
    float ldst = 8.0, t = 1.5, T = animTime + ldst, fogT = 0.0;
    float3 lpos = float3(disp(T) * 0.5, T);

    for (int i = 0; rez.a < 0.99 && i < 130; i++) {
        float3 pos = ro + t * rd;
        float2 mpv = map(pos);
        float den = clamp(mpv.x - 0.3, 0.0, 1.0) * 1.12,
              dn  = clamp(mpv.x + 2.0, 0.0, 3.0);

        float4 C = (float4)0;
        if (mpv.x > 0.6) {
            C = float4(sin(float3(5.0, 0.4, 0.2) + mpv.y * 0.1 + sin(pos.z * 0.4) * 0.5 + 1.8) * 0.5 + 0.5, 0.08);
            C *= den * den * den;
            C.rgb *= linstep(4.0, -2.5, mpv.x) * 2.3;
            float dif = clamp((den - map(pos + 0.8).x) / 9.0, 0.001, 1.0)
                      + clamp((den - map(pos + 0.35).x) / 2.5, 0.001, 1.0);
            C.xyz *= den * (float3(0.005, 0.045, 0.075) + 1.5 * dif * float3(0.033, 0.07, 0.03));
        }

        float fogC = exp(t * 0.2 - 2.2);
        C += float4(0.06, 0.11, 0.11, 0.1) * clamp(fogC - fogT, 0.0, 1.0);
        fogT = fogC;

        rez += C * (1.0 - rez.a);
        t += clamp(0.5 - dn * dn * 0.05, 0.09, 0.3);
    }
    return rez;
}

// --- Saturation-preserving interpolation ---

float getsat(float3 c) {
    float mx = max(max(c.x, c.y), c.z);
    if (mx <= 0.0) return 0.0;
    return 1.0 - min(min(c.x, c.y), c.z) / mx;
}

float3 iLerp(float3 a, float3 b, float x) {
    float3 ic = lerp(a, b, x);
    float lgt = dot(float3(1, 1, 1), ic),
          sd  = abs(getsat(ic) - lerp(getsat(a), getsat(b), x));
    float3 dir = normalize(ic * 3.0 - lgt);
    ic += 1.5 * dir * sd * lgt * dot(dir, normalize(ic));
    return ic;
}

// --- Entry point ---

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 R = resolution;
    float2 q = fragCoord / R;
    float2 p = (fragCoord - 0.5 * R) / R.y;
    bsMo = (float2)0;
    prm1 = smoothstep(-0.4, 0.4, sin(time * 0.3));

    float animTime = time * 3.0,
          tgtDst   = 3.5,
          dspAmp   = 0.85;
    float3 P = float3(sin(time) * 0.5, 0.0, animTime);
    P.xy += disp(P.z) * dspAmp;

    float3 target    = normalize(P - float3(disp(animTime + tgtDst) * dspAmp, animTime + tgtDst)),
           rightdir  = normalize(cross(target, float3(0, 1, 0))),
           updir     = normalize(cross(rightdir, target)),
           rightdir2 = cross(updir, target),
           D         = normalize(p.x * rightdir2 + p.y * updir - target);
    D.xy = mul(D.xy, rot(-disp(animTime + 3.5).x * 0.2));

    float3 C = render(P, D, animTime).rgb;

    C = iLerp(C, C.bgr, min(prm1, 0.95));
    C = pow(C, float3(0.55, 0.65, 0.6)) * float3(1.0, 0.97, 0.9);
    C *= pow(16.0 * q.x * q.y * (1.0 - q.x) * (1.0 - q.y), 0.12) * 0.7 + 0.3;

    float3 color = C;

    // Darken / desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
