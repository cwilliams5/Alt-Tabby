// Neon Cubes — converted from Shadertoy GLSL

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

float3 H(float a) {
    return cos(radians(float3(90, 30, -30)) - a * 6.2832) * 0.5 + 0.5;
}

float2x2 makeRot(float a) {
    float4 cs = cos(a * 1.571 + float4(0, -1.571, 1.571, 0));
    return float2x2(cs.x, cs.y, cs.z, cs.w);
}

float cubes(float3 p) {
    p = abs(p - round(p));
    return max(p.x, max(p.y, p.z));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float aa = 2.0;
    float d, s;
    float2 R = resolution;
    float2 m = (float2)(cos(time / 8.0) * 0.5 + 0.5);
    float2 o;
    float3 c = (float3)0;
    float3 cam = float3(0.5, 0.5, time / 4.0);
    float3 u, v;

    float2x2 pitch = makeRot(m.y);
    float2x2 yaw = makeRot(m.x);

    for (int k = 0; k < (int)(aa * aa); k++) {
        o = float2(k % 2, k / 2) / aa;
        u = normalize(float3((fragCoord - 0.5 * R + o) / R.y, 0.7));
        u.yz = mul(pitch, u.yz);
        u.xz = mul(yaw, u.xz);
        d = 0.0;
        for (int i = 0; i < 50; i++) {
            s = smoothstep(0.2, 0.25, cubes(cam + u * d) - 0.05);
            if (s < 0.01) break;
            d += s;
        }
        v = d * 0.01 * H(length(u.xy));
        c += v + max(v, 0.5 - H(d));
    }
    c /= aa * aa;
    float3 color = pow(max(c, (float3)0), (float3)(1.0 / 2.2));

    // Post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float alpha = max(color.r, max(color.g, color.b));
    return float4(color * alpha, alpha);
}
