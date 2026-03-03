// 2022 myth0genesis
// Volumetric Fire
// Most code is from nimitz's Protean clouds
// https://www.shadertoy.com/view/3l23Rh

const mat3 m3 = mat3( 0.3338,  0.56034, -0.71817,
                     -0.87887, 0.32651, -0.15323,
                      0.15162, 0.69596,  0.61339) * 1.93;

float LinStep(float mn, float mx, float x) {
    return clamp((x - mn) / (mx - mn), 0.0, 1.0);
}

mat2 rotate(float a) {
    float c = cos(a);
    float s = sin(a);
    return mat2( c, s,
                -s, c);
}

// nimitz's genius fast gyroid fBm
float gyroidFBM3D(vec3 p, float cl) {
    float d = 0.0;
    p *= 0.185;
    p.z -= iTime;
    float z = 1.0;
    float trk = 1.0;
    float dspAmp = 0.1;
    for(int i = 0; i < 5; i++) {
        p += sin(p.yzx * 1.5 * trk) * dspAmp;
        d -= abs(dot(cos(p), sin(p.zxy)) * z);
        z *= 0.7;
        trk *= 1.4;
        p = p * m3;
        // move it faster to hide banding between steps
        p -= iTime * 2.0;
    }
    // stepped back distance function to help with banding and color density
    return (cl + d * 6.5) * 0.5;
}

// nimitz's volumetric ray marcher (which seems to be loosely based on iq's)
// https://www.shadertoy.com/view/XslGRr
// I eliminated some diffuse passes because self-shadowing isn't necessary with "emissive" fire
vec3 transRender(vec3 ro, vec3 rd) {
    vec4 rez = vec4(0.0);
    float t = 20.0;
    for(int i = 0; i < 100; i++) {
        if(rez.w > 0.99) break;
        vec3 pos = ro + t * rd;
        float mpv = gyroidFBM3D(pos, -pos.z);
        float den = clamp(mpv - 0.2, 0.0, 1.0) * 0.71;
        float dn = clamp((mpv * 2.0), 0.0, 3.0);
        vec4 col = vec4(0.0);
        if(mpv > 0.6) {
            col = vec4(11.0, 1.0, 0.0, 0.08);
            // accumulate den linearly
            col *= den;
            col.xyz *= LinStep(3.0, -1.0, mpv) * 3.0;
            // just calculate one diffuse pass for a color gradient
            // and use precalculated distance to speed things up a bit
            float dif = clamp((den - mpv + 1.5) * 0.125, 0.08, 1.0);
            col.xyz *= den * (1.5 * vec3(0.005, 0.045, 0.075) + 1.5 * vec3(0.033, 0.05, 0.030) * dif);
        }
        rez += col * (1.0 - rez.w);
        // kept steps as close together as I dared to hide banding
        t += clamp(0.25 - dn * dn * 0.05, 0.15, 1.4);
    }
    return clamp(rez.xyz, 0.0, 1.0);
}
void mainImage( out vec4 fragColor, in vec2 fragCoord ) {
    vec2 uv = (fragCoord.xy - 0.5 * iResolution.xy) / iResolution.y;
    vec3 ro = vec3(0.0, 0.0, -3.0);

    // uncomment for forward movement
//    ro += vec3(0.0, iTime * 30.0, 0.0);
    vec3 rd = normalize(vec3(uv.x, 1.0, uv.y));
//    rd.xy *= rotate(sin(iTime * 0.5));
    if(iMouse.z > 0.0) {
//        rd.xy *= rotate((iMouse.x - 0.5 * iResolution.x) * 2.0 / iResolution.x);
        rd.xy *= rotate(2.0 * (iMouse.x / iResolution.x - 0.5));
    }
    vec3 col = transRender(ro, rd);
    fragColor = vec4(col,1.0);
}