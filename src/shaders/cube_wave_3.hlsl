// Cube Wave 3 - FabriceNeyret2 (Shadertoy lcSGDD)
// https://www.shadertoy.com/view/lcSGDD
// Converted from GLSL to HLSL for Alt-Tabby

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

float segment(float2 p, float2 a, float2 b) {
    p -= a;
    b -= a;
    return length(p - b * clamp(dot(p, b) / dot(b, b), 0.0, 1.0));
}

// rot(a) macro: cos(a+vec4(0,pi/2,-pi/2,0)) = (cos(a),-sin(a),sin(a),cos(a))
// GLSL mat2(vec4) fills column-major; HLSL float2x2 fills row-major.
// With mul(M,v), row-major (cos,-sin,sin,cos) gives same result as GLSL v*M column-major.
float2x2 rot(float a) {
    float4 v = cos(a + float4(0, 1.57, -1.57, 0));
    return float2x2(v.x, v.y, v.z, v.w);
}

static float gt;

float2 T(float3 p) {
    p.xy = mul(rot(-gt), p.xy);
    p.xz = mul(rot(0.785), p.xz);
    p.yz = mul(rot(-0.625), p.yz);
    return p.xy;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 R = resolution;
    float2 U = 10.0 * fragCoord / R.y;
    float2 M = float2(2, 2.3);
    float2 I = floor(U / M) * M;
    float2 J, X;
    U = fmod(U, M);
    float4 O = (float4)0;

    for (int k = 0; k < 4; k++) {
        X = float2(k % 2, k / 2) * M;
        J = I + X;
        if ((int)(J.x / M.x) % 2 > 0) X.y += 1.15;
        gt = tanh(-0.2 * (J.x + J.y) + fmod(2.0 * time, 10.0) - 1.6) * 0.785;
        for (float a = 0.0; a < 6.0; a += 1.57) {
            float3 A = float3(cos(a), sin(a), 0.7);
            float3 B = float3(-A.y, A.x, 0.7);
            O += smoothstep(15.0 / R.y, 0.0, segment(U - X, T(A), T(B)));
            O += smoothstep(15.0 / R.y, 0.0, segment(U - X, T(A), T(A * float3(1, 1, -1))));
            A.z = -A.z; B.z = -B.z;
            O += smoothstep(15.0 / R.y, 0.0, segment(U - X, T(A), T(B)));
        }
    }

    float3 col = O.rgb;

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float al = max(col.r, max(col.g, col.b));
    return float4(col * al, al);
}
