cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};

// originals from gaz fractal 62
#define R(p,a,r) lerp(a*dot(p,a),p,cos(r))+sin(r)*cross(p,a)
#define H(h) (cos((h)*6.3+float3(25,20,21))*2.5+.5)

float3 glsl_mod(float3 x, float y) {
    return x - y * floor(x / y);
}

float happy_star(float2 uv, float anim) {
    uv = abs(uv);
    float2 pos = min(uv.xy / uv.yx, anim);
    float p = (2.0 - pos.x - pos.y);
    return (2.0 + p * (p * p - 1.5)) / (uv.x + uv.y);
}

float hash(int3 p) {
    int n = p.x * 3 + p.y * 113 + p.z * 311;
    n = (n << 13) ^ n;
    n = n * (n * n * 15731 + 789221) + 1376312589;
    return float(n & 0x0fffffff) / float(0x0fffffff);
}

float noise(float3 x) {
    int3 i = int3(floor(x));
    float3 f = frac(x);
    f = f * f * (3.0 - 2.0 * f);

    return lerp(lerp(lerp(hash(i + int3(0, 0, 0)),
                          hash(i + int3(1, 0, 0)), f.x),
                     lerp(hash(i + int3(0, 1, 0)),
                          hash(i + int3(1, 1, 0)), f.x), f.y),
                lerp(lerp(hash(i + int3(0, 0, 1)),
                          hash(i + int3(1, 0, 1)), f.x),
                     lerp(hash(i + int3(0, 1, 1)),
                          hash(i + int3(1, 1, 1)), f.x), f.y), f.z);
}

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float4 O = (float4)0;
    float2 uv = (fragCoord - 0.5 * resolution) / resolution.y;
    float t2 = time * 0.1 + ((0.25 + 0.05 * sin(time * 0.1)) / (length(uv) + 0.51)) * 2.2;
    float si = sin(t2);
    float co = cos(t2);
    // GLSL mat2(co, si, -si, co) is column-major; transpose for HLSL row-major
    float2x2 ma = float2x2(co, -si, si, co);
    float3 r = float3(resolution, 1.0);
    float3 n1 = (float3)0;
    float3 d = normalize(float3((fragCoord * 2.0 - r.xy) / r.y, 1));

    float a, s, e, g = 0.;
    for (float i = 0.; ++i < 110.;
         O.xyz += lerp((float3)1, H(g * 0.1), sin(0.8)) * 1.0 / e / 8e3)
    {
        float c2 = noise(n1);
        n1 = g * d + c2;

        n1.xy = mul(n1.xy, -ma);
        float4 q = float4(n1, sin(time * 0.15) * 0.5);
        q.xy = mul(q.xy, ma);

        for (float j = 0.; j++ < 4.;) {
            for (float k = 0.; k++ < 3.;) {
                n1.x = cos(q.w * i + j);
                n1.y *= cos(q.x * i + j * q.z);
            }
        }

        a = 20.;
        n1 = glsl_mod(n1 - a, a * 2.) - a;
        s = 3. + c2;

        for (int ii = 0; ii++ < 8;) {
            n1 = 0.3 - abs(n1);

            if (n1.x < n1.z) n1 = n1.zyx;
            if (n1.z < n1.y) n1 = n1.xzy;
            if (n1.y < n1.x) n1 = n1.zyx;

            q = abs(q);
            q = q.x < q.y ? q.zwxy : q.zwyx;
            q = q.z < q.y ? q.xyzw : q.ywxz;

            s *= e = 1.4 + sin(time * 0.234) * 0.1;
            n1 = abs(n1) * e - float3(
                q.w + cos(time * 0.3 + 0.5 * cos(time * 0.3)) * 3.,
                120.,
                8. + cos(time * 0.5) * 5.);
        }

        g += e = length(n1.xy) / s;
    }

    uv *= 2.0 * (cos(time * 2.0) - 2.5);
    float anim = sin(time * 12.0) * 0.1 + 1.0;
    O += float4(happy_star(uv, anim) * float3(0.05, 1.2, 0.15) * 0.1, 0.0);

    // Alpha from brightness, darken/desaturate, premultiply
    float3 color = O.xyz;
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);
    float al = saturate(max(color.r, max(color.g, color.b)));
    color = saturate(color);
    return float4(color * al, al);
}
