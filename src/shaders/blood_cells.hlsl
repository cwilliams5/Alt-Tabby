// BloodCells - converted from Shadertoy (4ttXzj) by kuvkar
// https://www.shadertoy.com/view/4ttXzj
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

static const float BEAT = 4.0;

float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

float cells(float2 uv) {
    uv = lerp(sin(uv + float2(1.57, 0)), sin(uv.yx * 1.4 + float2(1.57, 0)), 0.75);
    return uv.x * uv.y * 0.3 + 0.7;
}

float fbm(float2 uv) {
    float f = 200.0;
    float2 r = float2(0.9, 0.45);
    float2 tmp;
    float T = 100.0 + time * 1.3;
    T += sin(time * BEAT) * 0.1;

    for (int i = 1; i < 8; ++i) {
        uv.y -= T * 0.5;
        uv.x -= T * 0.4;
        tmp = uv;

        uv.x = tmp.x * r.x - tmp.y * r.y;
        uv.y = tmp.x * r.y + tmp.y * r.x;
        float m = cells(uv);
        f = smin(f, m, 0.07);
    }
    return 1.0 - f;
}

float3 g(float2 uv) {
    float2 off = float2(0.0, 0.03);
    float t = fbm(uv);
    float x = t - fbm(uv + off.yx);
    float y = t - fbm(uv + off);
    float s = 0.0025;
    float3 xv = float3(s, x, 0);
    float3 yv = float3(0, y, s);
    return normalize(cross(xv, -yv)).xzy;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float3 ld = normalize(float3(1.0, 2.0, 3.0));

    float2 uv = fragCoord / resolution;
    uv -= (float2)0.5;
    float a = resolution.x / resolution.y;
    uv.y /= a;
    float2 ouv = uv;
    float B = sin(time * BEAT);
    uv = lerp(uv, uv * sin(B), 0.035);
    float2 _uv = uv * 25.0;
    float f = fbm(_uv);

    // base color
    float4 fragColor = (float4)f;
    fragColor.rgb *= float3(1.0, 0.3 + B * 0.05, 0.1 + B * 0.05);

    float3 v = normalize(float3(uv, 1.0));
    float3 grad = g(_uv);

    // spec
    float3 H = normalize(ld + v);
    float S = max(0.0, dot(grad, H));
    S = pow(S, 4.0) * 0.2;
    fragColor.rgb += S * float3(0.4, 0.7, 0.7);

    // rim
    float R = 1.0 - clamp(dot(grad, v), 0.0, 1.0);
    fragColor.rgb = lerp(fragColor.rgb, float3(0.8, 0.8, 1.0), smoothstep(-0.2, 2.9, R));

    // edges
    fragColor.rgb = lerp(fragColor.rgb, (float3)0.0, smoothstep(0.45, 0.55, max(abs(ouv.y * a), abs(ouv.x))));

    // contrast
    fragColor = smoothstep(0.0, 1.0, fragColor);

    float3 color = fragColor.rgb;

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float alpha = max(color.r, max(color.g, color.b));
    return float4(color * alpha, alpha);
}
