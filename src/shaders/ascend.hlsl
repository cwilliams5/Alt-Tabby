// Ascend by bug
// License: CC BY-NC-SA 4.0
// https://www.shadertoy.com/view/33KBDm
// De-golfed and converted from GLSL

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

float3 tanh_approx(float3 x) {
    float3 x2 = x * x;
    return x * (27.0 + x2) / (27.0 + 9.0 * x2);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
    float3 o = (float3)0;
    float3 p = (float3)0;
    float3 q = (float3)0;
    float3 R = float3(resolution, 1.0);

    float i = 0, d = 0, a = 0, l = 0, k = 0, s = 0, x = 0;

    for (i = 0; i < 100; i += 1.0) {
        // Inner loop: build p, compute distances
        // p = normalize(vec3(P+P,R.y)-R)*i*.05
        p = normalize(float3(fragCoord + fragCoord, R.y) - R) * i * 0.05;
        p.z -= 3.0;
        q = p - float3(1.5, 0.7, 0);
        s = length(q);
        q.y = p.y - min(p.y, 0.7);
        l = length(q);
        p.y += time;
        d = min(length(p.xz), 1.0 - p.z);
        a = 0.01;

        [unroll]
        for (; a < 3.0; a += a) {
            // p.zy *= .1*mat2(8,6,-6,8)
            // GLSL mat2(8,6,-6,8) fills column-major: col0=(8,6), col1=(-6,8)
            // vec2 * mat2: result = (v.x*col0[0]+v.y*col1[0], v.x*col0[1]+v.y*col1[1])
            //   new_z = 0.1*(8*p.z + (-6)*p.y)
            //   new_y = 0.1*(6*p.z + 8*p.y)
            float pz = p.z, py = p.y;
            p.z = 0.1 * (8.0 * pz - 6.0 * py);
            p.y = 0.1 * (6.0 * pz + 8.0 * py);

            // d -= N(4.,.2) = abs(dot(sin(p/a*4.), p-p+a*.2))
            // p-p = 0, so p-p+a*.2 = vec3(a*.2)
            d -= abs(dot(sin(p / a * 4.0), (float3)(a * 0.2)));
            // l -= N(5.,.01)
            l -= abs(dot(sin(p / a * 5.0), (float3)(a * 0.01)));
        }

        // Outer loop increment expression (expanded V macro calls):

        // V * mix(vec3(0,1.5,3), q=vec3(3,1,.7), x=max(2.-l,0.)*.8)
        // First: V expands to: d = min(d,0.), k += a = d*k-d, o += a/exp(s*1.3)*(1.+d)
        d = min(d, 0.0);
        a = d * k - d;
        k += a;
        x = max(2.0 - l, 0.0) * 0.8;
        q = float3(3, 1, 0.7);
        o += a / exp(s * 1.3) * (1.0 + d)
            * lerp(float3(0, 1.5, 3), q, x);

        // d = l
        d = l;

        // V * q * 20.
        d = min(d, 0.0);
        a = d * k - d;
        k += a;
        o += a / exp(s * 1.3) * (1.0 + d) * q * 20.0;

        // o += (x-x*k)/s/4e2
        o += (x - x * k) / s / 400.0;
    }

    float3 col = tanh_approx(o);

    // darken/desaturate
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // alpha from brightness, premultiply
    float alpha = max(col.r, max(col.g, col.b));
    return float4(col * alpha, alpha);
}
