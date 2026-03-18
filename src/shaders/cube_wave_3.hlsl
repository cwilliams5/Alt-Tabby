// Cube Wave 3 - FabriceNeyret2 (Shadertoy lcSGDD)
// https://www.shadertoy.com/view/lcSGDD
// Converted from GLSL to HLSL for Alt-Tabby

float segment(float2 p, float2 a, float2 b) {
    p -= a;
    b -= a;
    return length(p - b * saturate(dot(p, b) / dot(b, b)));
}

float2x2 rot(float a) {
    float s, c;
    sincos(a, s, c);
    return float2x2(c, -s, s, c);
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
    U = U - M * floor(U / M);
    float4 O = (float4)0;

    float _timeMod = fmod(2.0 * time, 10.0);
    for (int k = 0; k < 4; k++) {
        X = float2(k % 2, k / 2) * M;
        J = I + X;
        if ((int)(J.x / M.x) % 2 > 0) X.y += 1.15;
        gt = tanh(-0.2 * (J.x + J.y) + _timeMod - 1.6) * 0.785;
        for (float a = 0.0; a < 6.0; a += 1.57) {
            float _sa, _ca;
            sincos(a, _sa, _ca);
            float3 A = float3(_ca, _sa, 0.7);
            float3 B = float3(-A.y, A.x, 0.7);
            O += smoothstep(15.0 / R.y, 0.0, segment(U - X, T(A), T(B)));
            O += smoothstep(15.0 / R.y, 0.0, segment(U - X, T(A), T(A * float3(1, 1, -1))));
            A.z = -A.z; B.z = -B.z;
            O += smoothstep(15.0 / R.y, 0.0, segment(U - X, T(A), T(B)));
        }
    }

    float3 col = O.rgb;

    return AT_PostProcess(col);
}
