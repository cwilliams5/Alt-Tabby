float random (in vec2 _st) {
    return fract(sin(dot(_st.xy, vec2(0.89,-0.90)))*757.153);
}

// Based on Morgan McGuire @morgan3d
// https://www.shadertoy.com/view/4dS3Wd
float noise (in vec2 _st) {
    vec2 i = floor(_st);
    vec2 f = fract(_st);

    // Four corners in 2D of a tile
    float a = random(i);
    float b = random(i + vec2(1.0, 0.0));
    float c = random(i + vec2(0.0, 1.0));
    float d = random(i + vec2(1.0, 1.0));

    vec2 u = f * f * (3. - 2. * f);

    return mix(a, b, u.x) + (c - a)* u.y * (1. - u.x) + (d - b) * u.x * u.y;
}

float fbm ( in vec2 _st) {
    float v = sin(iTime*0.2)*0.15;
    float a = 0.8;
    vec2 shift = vec2(100.);
    // Rotate to reduce axial bias
    mat2 rot = mat2(cos(0.5), sin(1.0),
                    -sin(0.5), acos(0.5));
    for (int i = 0; i < 5; ++i) {
        v += a * noise(_st);
        _st = rot * _st * 2. + shift;
        a *= 0.01;
    }
    return v;
}

void mainImage( out vec4 fragColor, in vec2 fragCoord ) {
    vec2 st = (2.*fragCoord - iResolution.xy) / min(iResolution.x, iResolution.y) * 1.7;

    vec2 co = st;
    float len;
    for (int i = 0; i < 3; i++) {
        len = length(co);
        co.x +=  sin(co.y + iTime * 0.620)*0.1;
        co.y +=  cos(co.x + iTime * 0.164)*0.1;
    }
    len -= 3.;

    vec3 col = vec3(0.);

    vec2 q = vec2(0.);
    q.x = fbm( st + 1.0);
    q.y = fbm( st + vec2(-0.45,0.65));

    vec2 r = vec2(0.);
    r.x = fbm( st + q + vec2(0.57,0.52)+ 0.5*iTime );
    r.y = fbm( st + q + vec2(0.34,-0.57)+ 0.4*iTime);

    for (float i = 0.; i < 3.; i++) {
        r += 1. / abs(mod(st.y, 1.2* i) * 500.) * 1.;//Virtical line
        r += 1. / abs(mod(st.x, 0.3 * i) * 500.) * 1.;//Horizontal line
        r += 1. / abs(mod(st.y + st.x, 0.6 * i) * 500.) * 1.;//Diagonal line
        r += 1. / abs(mod(st.y - st.x, 0.6 * i) * 500.) * 1.;//Diagonal line
    }
    float f = fbm(st+r);

    col = mix(col, cos(len + vec3(0.2, 0.0, -0.5)), 1.0);
    col = mix(vec3(0.730,0.386,0.372), vec3(0.397,0.576,0.667), col);

    fragColor = vec4(2.0*(f*f*f+.6*f*f+.5*f)*col,1.);
}