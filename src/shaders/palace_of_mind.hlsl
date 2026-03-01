cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};

float glsl_mod(float x, float y) {
    return x - y * floor(x / y);
}

float3 glsl_mod3(float3 x, float y) {
    return x - y * floor(x / y);
}

float2 rot(float2 p, float r) {
    // GLSL mat2(cos,sin,-sin,cos) is column-major; transpose for HLSL row-major
    float2x2 m = float2x2(cos(r), -sin(r), sin(r), cos(r));
    return mul(m, p);
}

float cube(float3 p, float3 s) {
    float3 q = abs(p);
    float3 m = max(s - q, 0.0);
    return length(max(q - s, 0.0)) - min(min(m.x, m.y), m.z);
}

float hasira(float3 p, float3 s) {
    float2 q = abs(p.xy);
    float2 m = max(s.xy - q.xy, float2(0.0, 0.0));
    return length(max(q.xy - s.xy, 0.0)) - min(m.x, m.y);
}

float closs(float3 p, float3 s) {
    float d1 = hasira(p, s);
    float d2 = hasira(p.yzx, s.yzx);
    float d3 = hasira(p.zxy, s.zxy);
    return min(min(d1, d2), d3);
}

float rand(float2 co) {
    return frac(sin(dot(co.xy, float2(12.9898, 78.233))) * 43758.5453);
}

float noise(float2 st) {
    float2 i = floor(st);
    float2 f = frac(st);

    float a = rand(i);
    float b = rand(i + float2(1.0, 0.0));
    float c = rand(i + float2(0.0, 1.0));
    float d = rand(i + float2(1.0, 1.0));

    float2 u = f * f * (3.0 - 2.0 * f);

    return lerp(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

float dist(float3 p) {
    float k = 1.2;
    float3 sxyz = floor((p.xyz - 0.5 * k) / k) * k;
    float sz = rand(sxyz.xz);
    float t = time * 0.05 + 50.0;
    p.xy = rot(p.xy, t * sign(sz - 0.5) * (sz * 0.5 + 0.7));
    p.z += t * sign(sz - 0.5) * (sz * 0.5 + 0.7);
    p = glsl_mod3(p, k) - 0.5 * k;
    float s = 7.0;
    p *= s;
    p.yz = rot(p.yz, 0.76);
    for (int i = 0; i < 4; i++) {
        p = abs(p) - 0.4 + (0.25 + 0.1 * sz) * sin(t * (0.5 + sz));
        p.xy = rot(p.xy, t * (0.7 + sz));
        p.yz = rot(p.yz, 1.3 * t + sz);
    }

    float d1 = closs(p, float3(0.06, 0.06, 0.06));

    return d1 / s;
}

float3 gn(float3 p) {
    const float h = 0.001;
    const float2 k = float2(1.0, -1.0);
    return normalize(k.xyy * dist(p + k.xyy * h) +
                     k.yyx * dist(p + k.yyx * h) +
                     k.yxy * dist(p + k.yxy * h) +
                     k.xxx * dist(p + k.xxx * h));
}

float3 lighting(float3 p, float3 view) {
    float3 normal = gn(p);
    float vn = clamp(dot(-view, normal), 0.0, 1.0);
    float3 ld = normalize(float3(-1, 0.9 * sin(time * 0.5) - 0.1, 0));
    float NdotL = max(dot(ld, normal), 0.0);
    float3 R = normalize(-ld + NdotL * normal * 2.0);
    float spec = pow(max(dot(-view, R), 0.0), 20.0) * clamp(sign(NdotL), 0.0, 1.0);
    float3 col = float3(1, 1, 1) * (pow(vn, 2.0) * 0.9 + spec * 0.3);
    float k = 0.5;
    float ks = 0.9;
    float2 sxz = floor((p.xz - 0.5 * ks) / ks) * ks;
    float sx = rand(sxz);
    float sy = rand(sxz + 100.1);
    float emissive = clamp(0.001 / abs(glsl_mod(abs(p.y * sx + p.x * sy) + time * sign(sx - 0.5) * 0.4, k) - 0.5 * k), 0.0, 1.0);
    return clamp(col * float3(0.3, 0.5, 0.9) * 0.7 + emissive * float3(0.2, 0.2, 1.0), 0.0, 1.0);
}

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 p = (fragCoord.xy * 2.0 - resolution) / resolution.yy;
    float3 tn = time * float3(0.0, 0.0, 1.0) * 0.3;
    float tk = time * 0.3;
    float3 ro = float3(1.0 * cos(tk), 0.2 * sin(tk), 1.0 * sin(tk)) + tn;
    float3 ta = float3(0.0, 0.0, 0.0) + tn;
    float3 cdir = normalize(ta - ro);
    float3 up = float3(0., 1., 0.);
    float3 side = cross(cdir, up);
    up = cross(side, cdir);
    float fov = 1.3;
    float3 rd = normalize(p.x * side + p.y * up + cdir * fov);
    float d = 0.0;
    float t = 0.1;
    float far = 18.;
    float near = t;
    float hit = 0.0001;
    for (int i = 0; i < 100; i++) {
        d = dist(ro + rd * t);
        t += d;
        if (hit > d) break;
    }
    float3 bcol = float3(0.1, 0.1, 0.8);
    float3 col = lighting(ro + rd * t, rd);

    col = lerp(bcol, col, pow(clamp((far - t) / (far - near), 0.0, 1.0), 2.0));

    col.x = pow(col.x, 2.2);
    col.y = pow(col.y, 2.2);
    col.z = pow(col.z, 2.2);
    col *= 2.0;

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float al = saturate(max(col.r, max(col.g, col.b)));
    col = saturate(col);
    return float4(col * al, al);
}
