#define pow(x,n) pow(abs(x),n)

vec2 hash( in vec2 x )  // replace this by something better
{
    const vec2 k = vec2( 0.3183099, 0.3678794 );
    x = x*k + k.yx;
    return -1.0 + 2.0*fract( 16.0 * k*fract( x.x*x.y*(x.x+x.y)) );
}

// by iq - https://www.shadertoy.com/view/XdXGW8
float noise(in vec2 p) {
    vec2 i = floor( p );
    vec2 f = fract( p );

	vec2 u = f*f*(3.0-2.0*f);

    return mix( mix( dot( hash( i + vec2(0.0,0.0) ), f - vec2(0.0,0.0) ),
                     dot( hash( i + vec2(1.0,0.0) ), f - vec2(1.0,0.0) ), u.x),
                mix( dot( hash( i + vec2(0.0,1.0) ), f - vec2(0.0,1.0) ),
                     dot( hash( i + vec2(1.0,1.0) ), f - vec2(1.0,1.0) ), u.x), u.y);
}


float heightmap(vec2 p) {
    float h = 0.;
    vec2 q = 4. * p + noise(-4. * p + iTime * vec2(-.07, .03));
    vec2 r = 7. * p + vec2(37., 59.) + noise(5. * p + iTime * vec2(.08, .03));
    vec2 s = 3. * p + noise(5. * p + iTime * vec2(.1, .05) + vec2(13., 37.));
    float smoothAbs = .2;
    h += 1. * noise(s);
    h += .9 * pow(noise(q), 1. + smoothAbs);
    h += .7 * pow(noise(r), 1. + smoothAbs);

    h = .65 * h + .33;
    return h;
}

vec3 calcNormal(vec2 p) {
    vec2 e = vec2(1e-3, 0);
    return normalize(vec3(
        heightmap(p - e.xy) - heightmap(p + e.xy),
        heightmap(p - e.yx) - heightmap(p + e.yx),
        -2. * e.x));
}

vec3 getColor(float x) {
    vec3 a = vec3(.1, .0, .03);
    vec3 b = vec3(1., .05, .07);
    vec3 c = vec3(.9, .2, .3);
    return mix(a, mix(b, c, smoothstep(.4, .9, x)), smoothstep(.0, .9, x));
}


void mainImage( out vec4 fragColor, in vec2 fragCoord ) {
    vec2 uv = fragCoord/iResolution.y;
    float h = heightmap(uv);
    vec3 v = vec3(h);
    v.yz *= 3.;
    vec3 nor = calcNormal(uv);
    nor.xy *= .4;
    nor = normalize(nor);

    vec3 mat = getColor(h);
    mat = clamp(mat, 0., 1.);
    vec3 ld = normalize(vec3(1,-1.,1));
    vec3 ha = normalize(ld - vec3(0.,0,-1));

    vec3 col = vec3(0);
    col += mat * .8;
    col += .2 * mat * pow(max(dot(normalize(nor + vec3(.0,0,0)), -ld), 0.), 3.);
    col += .3 * h * pow(dot(normalize(nor + vec3(.0,0,0)), ha), 20.);

    fragColor = vec4(col, 1.);
}
