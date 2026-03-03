
// Credits to TDM https://www.shadertoy.com/view/Ms2SD1

float smin(float a, float b, float h)
{
    float k = clamp((a-b)/ h * .5 + .5, 0., 1.);
    return mix(a,b,k) - k * (1.-k) * h;
}

mat2 rot(float a)
{
    return mat2(cos(a), -sin(a), sin(a), cos(a));
}

float sph(vec3 p, float r)
{
    return length(p) - r;
}

float box(vec3 p, vec3 s)
{
    p = abs(p) - s;
    return max(p.x, max(p.y,p.z));
}

float repeat(float p, float s)
{
    return (fract(p/s-.5)-.5)*s;
}

vec2 repeat(vec2 p, vec2 s)
{
    return (fract(p/s-.5)-.5)*s;
}

vec3 repeat(vec3 p, vec3 s)
{
    return (fract(p/s-.5)-.5)*s;
}

vec3 kifs(vec3 p, float t)
{
    p.xz = repeat(p.xz, vec2(10.));
    p.xz = abs(p.xz);

    vec2 s = vec2(10,7) * 0.7;
    for(float i = 0.; i < 5. ; ++i)
    {
        p.xz *= rot(t);
        p.xz = abs(p.xz) - s;
        p.y -= 0.1*abs(p.z);
        s *= vec2(0.68, 0.55);
    }

    return p;
}

vec3 kifs3d(vec3 p, float t)
{
    p.xz = repeat(p.xz, vec2(32.));
    p = abs(p);

    vec2 s = vec2(10,7) * 0.6;
    for(float i = 0.; i < 5. ; ++i)
    {
        p.yz *= rot(t * .7);
        p.xz *= rot(t);
        p.xz = abs(p.xz) - s;
        p.y -= 0.1*abs(p.z);
        s *= vec2(0.68, 0.55);
    }

    return p;
}

vec3 tunnel(vec3 p)
{
    vec3 off = vec3(0);
    float dd = p.z * 0.02;
    dd = floor(dd) + smoothstep(0., 1., smoothstep(0., 1., fract(dd)));
    dd *= 1.7;
    off.x += sin(dd) * 10.;
    //off.y += sin(dd * 0.7) * 10.;

    return off;
}

float fire = 0.;
float solid(vec3 p)
{
    float t = iTime * .2;
    vec3 pp = p;
    vec3 p5 = p;
    pp += tunnel(p);

    float path = abs(pp.x) - 1.;

    vec3 p2 = kifs(p, 0.5);
    vec3 p3 = kifs(p + vec3(1,0,0), 1.9);

    float d5 = -1.;
    p5.xy *= rot(2.8);
    p5.xz *= rot(0.5);


    float trk = 1.;
    float z = 1.;
    int iterations = 10;
    for(int i = 0; i < iterations; ++i)
    {
        p5 += sin(p5.zxy*0.75*trk + t*trk*.8);
        d5 -= abs(dot(cos(p5), sin(p5.yzx)) * z);
        trk *= 1.6;
        z *= 0.4;

        p5.y += t * 3.;
    }

    float d;

    float b1 = box(p2, vec3(1,1,0.5));
    float b2 = box(p3, vec3(0.5,1.3,1));

    float m1 = max(abs(b1), abs(b2)) - 0.2;
    d = m1;
    d = max(d, -path);
    d5 = abs(d5);
    d += + sin(iTime * 0.1)*.3+.5;
    if(p5.y - t * 3. * float(iterations) > -10.)
    {
        d = smin(d, d5, 3.);
    }

    fire += 0.2 / (0.1 + abs(d));

    return d;
}

vec3 lpos = vec3(0,200,200);
float moonlight = 0.;
float ghost(vec3 p)
{
    vec3 p2 = kifs3d(p - vec3(0,2,3), 0.8 + iTime * 0.1);
    vec3 p3 = kifs3d(p - vec3(3,0,0), 1.2 + iTime * 0.07);

    float b1 = box(p2, vec3(5));
    float b2 = box(p3, vec3(3));

    float m1 = max(abs(b1), abs(b2)) - .2;

    float d = abs(m1) - 0.02;
    return d;
}

float hash( vec2 p ) {
	float h = dot(p,vec2(127.1,311.7));
    return fract(sin(h)*43758.5453123);
}

float noise( in vec2 p ) {
    vec2 i = floor( p );
    vec2 f = fract( p );
	vec2 u = f*f*(3.0-2.0*f);
    return -1.0+2.0*mix( mix( hash( i + vec2(0.0,0.0) ),
                     hash( i + vec2(1.0,0.0) ), u.x),
                mix( hash( i + vec2(0.0,1.0) ),
                     hash( i + vec2(1.0,1.0) ), u.x), u.y);
}

float noise(vec3 p) {
  vec3 ip=floor(p);
  p=fract(p);
  p=smoothstep(0.0,1.0,p);
  vec3 st=vec3(7,137,235);
  vec4 val=dot(ip,st) + vec4(0,st.y,st.z,st.y+st.z);
  vec4 v = mix(fract(sin(val)*5672.655), fract(sin(val+st.x)*5672.655), p.x);
  vec2 v2 = mix(v.xz,v.yw, p.y);
  return mix(v2.x,v2.y,p.z);
}

float sea_octave(vec2 uv, float choppy) {
    uv += noise(uv);
    vec2 wv = 1.0-abs(sin(uv));
    vec2 swv = abs(cos(uv));
    wv = mix(wv,swv,wv);
    return pow(1.0-pow(wv.x * wv.y,0.65),choppy);
}

float water(vec3 p)
{
    float freq = 0.16;//SEA_FREQ;
    float amp = 0.6;//SEA_HEIGHT;
    float choppy = 4.;//SEA_CHOPPY;
    float sea_time = 1. + iTime * 0.8;
    vec2 uv = p.xz; uv.x *= 0.75;
    const mat2 octave_m = mat2(1.6,1.2,-1.2,1.6);

    float d, h = 0.0;
    for(int i = 0; i < 5/*ITER_GEOMETRY*/; i++) {
    	d = sea_octave((uv+sea_time)*freq,choppy);
    	d += sea_octave((uv-sea_time)*freq,choppy);
        h += d * amp;
    	uv *= octave_m; freq *= 1.9; amp *= 0.22;
        choppy = mix(choppy,1.0,0.2);
    }
    return p.y - h + 1.;
}

bool isGhost = true;
bool isWater = true;
float at = 0.;
float at1 = 0.;
float map(vec3 p)
{
    float sol = solid(p);
    float wat = water(p);
    float gho = ghost(p);
    float d = smin(sol, wat, 0.1);
    isWater = wat < sol;
    isGhost = gho < d;
    at += 0.1/(0.1+abs(gho));
    at1 += 0.01/(0.1+abs(gho));
    at -= at1;
    at = (at + abs(at))/2.;

    // moon
    float d1 = length(p - lpos) - 30.;
    moonlight += 0.5/(0.5+(d1 + abs(d1)));
    d = min(d,d1);

    d *= 0.7;
    return d;
}

vec3 stars(vec2 uv)
{
    float iterations = 17.;
    float formuparam = 0.53;

    float volsteps = 20.;
    float stepsize = 0.1;

    float zoom = 0.200;
    float tile = 0.850;
    //float speed = 0.010;

    float brightness = 0.0015;
    float darkmatter = 0.300;
    float distfading = 0.730;
    float saturation = 0.850;

    uv *= rot(iTime * 0.001);
	vec3 dir=vec3(uv*zoom,1.);
	float time=1.;

	//volumetric rendering
	float s=0.1,fade=0.2;
	vec3 v=vec3(0.);
	for (float r=0.; r<volsteps; r++) {
		vec3 p=s*dir*.5;
		p = abs(vec3(tile)-mod(p,vec3(tile*2.))); // tiling fold
		float pa,a=pa=0.;
		for (float i=0.; i<iterations; i++) {
			p=abs(p)/dot(p,p)-formuparam; // the magic formula
			a+=abs(length(p)-pa); // absolute sum of average change
			pa=length(p);
		}
		float dm=max(0.,darkmatter-a*a*.001); //dark matter
		a*=a*a; // add contrast
		if (r>6.) fade*=1.-dm; // dark matter, don't render near
		//v+=vec3(dm,dm*.5,0.);
		v+=fade;
		v+=vec3(s,s*s,s*s*s*s)*a*brightness*fade; // coloring based on distance
		fade*=distfading; // distance fading
		s+=stepsize;
	}
	v=mix(vec3(length(v)),v,saturation); //color adjust
	return vec3(v*.01);

}

vec3 lin2srgb( vec3 cl )
{
	//cl = clamp( cl, 0.0, 1.0 );
	vec3 c_lo = 12.92 * cl;
	vec3 c_hi = 1.055 * pow(cl,vec3(0.41666)) - 0.055;
	vec3 s = step( vec3(0.0031308), cl);
	return mix( c_lo, c_hi, s );
}

vec3 srgb2lin( vec3 cs )
{
	vec3 c_lo = cs / 12.92;
	vec3 c_hi = pow( (cs + 0.055) / 1.055, vec3(2.4) );
	vec3 s = step(vec3(0.04045), cs);
	return mix( c_lo, c_hi, s );
}

vec3 getPixel(vec2 coord)
{
    vec2 uv = coord / iResolution.xy;
    uv = uv * 2.0 - 1.0;
    uv.x *= iResolution.x / iResolution.y;

    float adv = (sin(iTime * 0.01)+1.) * 100.;

    vec3 s = vec3(0,.6,0);
    vec3 t = vec3(0,.6,1);

    s.z += adv;
    t.z += adv;

    s -= tunnel(s);
    t -= tunnel(t);

    //vec3 r = normalize(vec3(uv, 1.));
    vec3 cz = normalize(t - s);
    vec3 cx = normalize(cross(vec3(0,1,0), cz));
    vec3 cy = normalize(cross(cz,cx));

    float fov = 1.;
    vec3 r = normalize(uv.x * cx + uv.y * cy + cz * fov);

    vec3 sky = vec3(0);

    vec3 p = s;
    vec2 off = vec2(0.01, 0.);
    vec3 n;
    float dd = 0.;
    float i = 0.;
    for(i = 0.; i < 100.; ++i)
    {
        float d = map(p);
        dd += d;
        if(dd > 1000.)
        {
            sky = stars(vec2(r.x,r.y));

            break;
        }
        if(d < 0.001)
        {
            if(!isGhost)
            {
                if(!isWater) break;

                n = normalize(map(p) - vec3(map(p - off.xyy), map(p - off.yxy), map(p - off.yyx)));

                r = reflect(r, n);
            }

            d = 0.01;
        }

        p += r*d;
    }

    vec3 l = normalize(p - lpos);

    float falloff = 3.;

    vec3 col = vec3(0);

    //col += pow(1.-i/101., 8.);
    col = vec3((dot(l, -n)*.5+.5) * (1. / (0.01 + dd * falloff)));
    col += pow(at * .2, 0.5) * vec3(1,0,0);
    col += pow(at1 * .2, 1.) * vec3(0,153./255.,153./255.);
    col += pow(moonlight * 2., 2.);
    col += pow(fire * 0.01, 2.) * vec3(1,0,0);
    col += sky;

    return col;
}

float hash( vec3 p ) {
	float h = dot(p,vec3(127.1,311.7, 527.53));
    return fract(sin(h)*43758.5453123);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec3 col = getPixel(fragCoord);


    col = pow(col,vec3(2.2));
    col = lin2srgb(col);
    //col = pow(col, vec3(3.));
    //col = col + (vec3(col.r + col.g + col.b) / 3.) * hash(vec3(fragCoord, 1.0)) * 50.;

    fragColor = vec4(col, 1.);
}
