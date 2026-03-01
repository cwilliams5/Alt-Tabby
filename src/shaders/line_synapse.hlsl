// LineSynapse
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

#define iterations 13
#define formuparam 0.53

#define volsteps 20
#define stepsize 0.1

#define zoom   0.800
#define tile   0.850

#define brightness 0.0015
#define darkmatter 0.300
#define distfading 0.730
#define saturation 0.850
#define S(a,b,val) smoothstep(a,b,val)

float3 glsl_mod(float3 x, float3 y) { return x - y * floor(x / y); }

float DistLine(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float t = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * t);
}

float N21(float2 p) {
    p = frac(p * float2(233.34, 851.73));
    p += dot(p, p + 23.45);
    return frac(p.x * p.y);
}

float2 N22(float2 p) {
    float n = N21(p);
    return float2(n, N21(p + n));
}

float2 GetPos(float2 id, float2 offs) {
    float2 n = N22(id + offs) * time;
    return offs + cos(n) * sin(n) * 0.5;
}

float Line(float2 p, float2 a, float2 b) {
    float d = DistLine(p, a, b);
    float m = S(0.06, 0.01, d);
    float d2 = length(a - b);
    m *= S(2.2, 0.8, d2) + S(0.05, 0.03, abs(d2 - 0.75));
    return m;
}

float Layer(float2 uv) {
    float m = 0.0;
    float2 gv = frac(uv) - 0.5;
    float2 id = floor(uv);

    float2 p[9];
    int idx = 0;
    for (float y = -1.0; y <= 1.0; y++) {
        for (float x = -1.0; x <= 1.0; x++) {
            p[idx++] = GetPos(id, float2(x, y));
        }
    }

    float t = time * 10.0;
    for (int i = 0; i < 9; i++) {
        m += Line(gv, p[4], p[i]);
        float2 j = (p[i] - gv) * 15.0;
        float sparkle = 1.0 / dot(j, j);
        m += sparkle * (sin(t + frac(p[i].x) * 10.0) * 0.5 + 0.5);
    }

    m += Line(gv, p[1], p[3]);
    m += Line(gv, p[1], p[5]);
    m += Line(gv, p[7], p[3]);
    m += Line(gv, p[7], p[5]);
    return m;
}

// Volumetric star field (originally mainVR)
float4 volumetric(float3 ro, float3 rd) {
    float s = 0.1, fade = 1.0;
    float3 v = (float3)0;
    for (int r = 0; r < volsteps; r++) {
        float3 p = ro + s * rd * 0.5;
        p = abs((float3)tile - glsl_mod(p, (float3)(tile * 2.0)));
        float pa = 0.0, a = 0.0;
        for (int i = 0; i < iterations; i++) {
            p = abs(p) / dot(p, p) - formuparam;
            // GLSL mat2 column-major → HLSL row-major (transposed)
            float cs = cos(time * 0.05);
            float sn = sin(time * 0.05);
            p.xy = mul(p.xy, float2x2(cs, -sn, sn, cs));
            a += abs(length(p) - pa);
            pa = length(p);
        }
        float dm = max(0.0, darkmatter - a * a * 0.001);
        a *= a * a;
        if (r > 6) fade *= 1.3 - dm;
        v += fade;
        v += float3(s, s * s, s * s * s * s) * a * brightness * fade;
        fade *= distfading;
        s += stepsize;
    }
    v = lerp((float3)length(v), v, saturation);
    return float4(v * 0.03, 1.0);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = fragCoord.xy / resolution.xy - 0.5;
    uv.y *= resolution.y / resolution.x;
    float3 dir = float3(uv * zoom, 1.0);

    // Line synapse network (layered at multiple scales)
    float m = 0.0;
    float t = time * 0.1;

    for (float i = 0.0; i <= 1.0; i += 1.0 / 7.0) {
        float z = frac(i * i + t);
        float sz = lerp(59.0, 0.5, z);
        float fade = S(0.0, 0.2, z) * S(1.0, 0.0, z);
        m += Layer(uv * sz + i * 200.0) * fade;
    }

    float3 base = sin(t * 5.0 * float3(0.345, 0.456, 0.657)) * 0.5 + 0.6;
    float3 col = m * base;
    col -= uv.y * base;

    // Volumetric star field
    float3 from = float3(1.0, 0.5, 0.5);
    float4 vr = volumetric(from, dir);
    float3 color = vr.rgb * col;

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float alpha = max(color.r, max(color.g, color.b));
    return float4(color * alpha, alpha);
}
