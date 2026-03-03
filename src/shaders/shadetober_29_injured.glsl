// mostly warping from https://iquilezles.org/articles/warp

// iq noise fn
float noise(vec3 p)
{
	vec3 ip=floor(p);
    p-=ip;
    vec3 s=vec3(7,157,113);
    vec4 h=vec4(0.,s.yz,s.y+s.z)+dot(ip,s);
    p=p*p*(3.-2.*p);
    h=mix(fract(sin(h)*43758.5),fract(sin(h+s.x)*43758.5),p.x);
    h.xy=mix(h.xz,h.yw,p.y);
    return mix(h.x,h.y,p.z);
}

float fbm( in vec2 x, in float hurst)
{
    float gain = exp2(-hurst);
    float f = 1.0;
    float a = 1.0;
    float t = 0.0;
    for( int i=0; i < 4; i++ )
    {
        t += a * noise((f*x).xyy);
        f *= 2.0;
        a *= gain;
    }
    return t;
}

void fbms(in vec2 uv, out vec3 color) {
    float h = 1.;
    vec2 t1 = vec2(fbm(uv, h), fbm(uv + vec2(4.3,-2.1)*sin(iTime * .02), h));
    vec2 t2 = vec2(fbm(uv + 2.*t1 + vec2(-1.9,3.9)*cos(iTime * .07), h),
                   fbm(uv + 2.*t1 + vec2(2.2,3.1)*sin(iTime * .05), h));
    float t3 = fbm(uv + 2.*t2 + vec2(5.6,1.4)*cos(iTime * .06), h);
    color = vec3(t3, t3 - 1., t3 - 1.);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec2 uv = (2. * fragCoord - iResolution.xy) / iResolution.y;
    uv *= 2.;
	uv += 10.;
    vec3 c;
    fbms(uv, c);
    fragColor = vec4(c, 1.);
}