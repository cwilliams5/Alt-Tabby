// Abstract Glassy Field - Converted from Shadertoy (4ttGDH)
// Author: Shane - License: CC BY-NC-SA 3.0
// Raymarched blobby field with fake glass refraction and glow

#define FAR 50.

// GLSL mod: x - y * floor(x/y) (differs from HLSL fmod for negatives)
float4 glsl_mod4(float4 x, float y) { return x - y * floor(x / y); }

// Camera path
float3 camPath(float t) {
    float a = sin(t * 0.11);
    float b = cos(t * 0.14);
    return float3(a*4. - b*1.5, b*1.7 + a*1.5, t);
}

// Spherized sinusoidal distance field
float map(float3 p) {
    p.xy -= camPath(p.z).xy;

    const float TAU = 6.2831853;
    float3 q = p.zxy;
    p = cos(glsl_mod4(float4(p*.315*1.25 + sin(glsl_mod4(float4(q*.875*1.25, 0), TAU).xyz), 0), TAU).xyz);

    float n = length(p);
    return (n - 1.025)*1.33;
}

// Ambient occlusion (based on IQ)
float cao(in float3 p, in float3 n) {
    float sca = 1., occ = 0.;
    [loop]
    for (float i = 0.; i < 5.; i++) {
        float hr = .01 + i*.35/4.;
        float dd = map(n * hr + p);
        occ += (hr - dd)*sca;
        sca *= .7;
    }
    return saturate(1. - occ);
}

// Normal via central differences
float3 nr(float3 p) {
    const float2 e = float2(.002, 0);
    return normalize(float3(map(p + e.xyy) - map(p - e.xyy),
                            map(p + e.yxy) - map(p - e.yxy),
                            map(p + e.yyx) - map(p - e.yyx)));
}

// Raymarcher with glow accumulation
float trace(in float3 ro, in float3 rd, inout float ac) {
    ac = 0.;
    float t = 0., h;
    [loop]
    for (int i = 0; i < 128; i++) {
        h = map(ro + rd*t);
        if (abs(h) < .001*(t*.25 + 1.) || t > FAR) break;
        t += h;
        if (abs(h) < .35) ac += (.35 - abs(h))/24.;
    }
    return min(t, FAR);
}

// Soft shadows
float sha(in float3 ro, in float3 rd, in float start, in float end, in float k) {
    float shade = 1.;
    float dist = start;
    [loop]
    for (int i = 0; i < 24; i++) {
        float h = map(ro + rd*dist);
        shade = min(shade, smoothstep(0.0, 1.0, k*h/dist));
        dist += clamp(h, .01, .2);
        if (abs(h) < .001 || dist > end) break;
    }
    return min(max(shade, 0.) + .4, 1.);
}

// 3D value noise (IQ)
float n3D(float3 p) {
    const float3 s = float3(7, 157, 113);
    float3 ip = floor(p); p -= ip;
    float4 h = float4(0., s.yz, s.y + s.z) + dot(ip, s);
    p = p*p*(3. - 2.*p);
    h = lerp(frac(sin(glsl_mod4(h, 6.231589))*43758.5453),
             frac(sin(glsl_mod4(h + s.x, 6.231589))*43758.5453), p.x);
    h.xy = lerp(h.xz, h.yw, p.y);
    return lerp(h.x, h.y, p.z);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    // Screen coordinates
    float2 u = (fragCoord - resolution.xy*.5) / resolution.y;

    // Camera setup
    float speed = 4.;
    float3 o = camPath(time*speed);
    float3 lk = camPath(time*speed + .25);
    float3 l = camPath(time*speed + 2.) + float3(0, 1, 0);

    // Ray direction with lens distortion
    float FOV = 3.14159/2.;
    float3 fwd = normalize(lk - o);
    float3 rgt = normalize(float3(fwd.z, 0, -fwd.x));
    float3 up = cross(fwd, rgt);

    float3 r = fwd + FOV*(u.x*rgt + u.y*up);
    r = normalize(float3(r.xy, (r.z - length(r.xy)*.125)));

    // Raymarch
    float accum;
    float t = trace(o, r, accum);

    float3 col = (float3)0;

    if (t < FAR) {
        float3 p = o + r*t;
        float3 n = nr(p);
        l -= p;
        float d = max(length(l), 0.001);
        l /= d;

        float at = 1./(1. + d*.05 + d*d*.0125);

        float ao = cao(p, n);
        float sh = sha(p, l, 0.04, d, 16.);

        float di = max(dot(l, n), 0.);
        float _sp0 = max(dot(reflect(r, n), l), 0.); float _sp2 = _sp0*_sp0; float _sp4 = _sp2*_sp2;
        float _sp8 = _sp4*_sp4; float _sp16 = _sp8*_sp8; float _sp32 = _sp16*_sp16; float sp = _sp32*_sp32;
        float fr = saturate(1.0 + dot(r, n));

        float3 tx = (float3).05;

        // Simple coloring
        float _fr2 = fr*fr; float _fr4 = _fr2*_fr2;
        col = tx*(di*.1 + ao*.25) + float3(.5, .7, 1)*sp*2. + float3(1, .7, .4)*(_fr4*_fr4)*.25;

        // Hue variation for depth
        col = lerp(col.xzy, col, di*.85 + .15);

        // Glow
        float3 accCol = float3(1, .3, .1)*accum;
        float3 gc = pow(min(float3(1.5, 1, 1)*accum, 1.), float3(1, 2.5, 12.))*.5 + accCol*.5;
        col += col*gc*12.;

        // Purple electric charge
        float hi = abs(fmod(t + time * 0.333333, 8.) - 4.) * 2.;
        float3 cCol = float3(.01, .05, 1)*col*1./(.001 + hi*hi*.2);
        col += lerp(cCol.yxz, cCol, n3D(p*3.));

        // Shading
        col *= ao*sh*at;
    }

    // Fog
    float3 fog = float3(.125, .04, .05)*(r.y*.5 + .5);
    col = lerp(col, fog, smoothstep(0., .95, t/FAR));

    // Vignette
    u = fragCoord / resolution.xy;
    col = lerp((float3)0, col, pow(16.0*u.x*u.y*(1.0 - u.x)*(1.0 - u.y), .125)*.5 + .5);

    // Gamma correction
    col = sqrt(saturate(col));

    return AT_PostProcess(col);
}
