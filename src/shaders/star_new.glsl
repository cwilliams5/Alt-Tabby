

#define iterations 17
#define formuparam 0.53

#define volsteps 20
#define stepsize 0.1

#define zoom   0.800
#define tile   0.850
#define speed  0.000

#define brightness 0.0015
#define darkmatter 0.300
#define distfading 0.730
#define saturation 0.850

#define pi 3.14159

#define thc(a,b) tanh(a*cos(b))/tanh(a)
#define ths(a,b) tanh(a*sin(b))/tanh(a)
#define sabs(x) sqrt(x*x+1e-2)
//#define sabs(x, k) sqrt(x*x+k)-0.1

float cc(float a, float b) {
    float f = thc(a, b);
    return sign(f) * pow(abs(f), 0.25);
}

float cs(float a, float b) {
    float f = ths(a, b);
    return sign(f) * pow(abs(f), 0.25);
}

vec3 pal(in float t, in vec3 a, in vec3 b, in vec3 c, in vec3 d) {
    return a + b*cos( 6.28318*(c*t+d) );
}

float h21(vec2 a) {
    return fract(sin(dot(a.xy, vec2(1., 10.233))) * 40000.5453123);
}

float mlength(vec2 uv) {
    return max(abs(uv.x), abs(uv.y));
}

float mlength(vec3 uv) {
    return max(max(abs(uv.x), abs(uv.y)), abs(uv.z));
}

float smin(float a, float b)
{
    float k = 0.12;
    float h = clamp(0.5 + 0.5 * (b-a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}
float sdSegment( in vec2 p, in vec2 a, in vec2 b )
{
    vec2 pa = p-a, ba = b-a;
    float h = clamp( dot(pa,ba)/dot(ba,ba), 0.0, 1.0 );
    return length( pa - ba*h );
}

float sdEllipse( in vec2 p, in vec2 ab )
{
    p = abs(p); if( p.x > p.y ) {p=p.yx;ab=ab.yx;}
    float l = ab.y*ab.y - ab.x*ab.x;
    float m = ab.x*p.x/l;      float m2 = m*m;
    float n = ab.y*p.y/l;      float n2 = n*n;
    float c = (m2+n2-1.0)/3.0; float c3 = c*c*c;
    float q = c3 + m2*n2*2.0;
    float d = c3 + m2*n2;
    float g = m + m*n2;
    float co;
    if( d<0.0 )
    {
        float h = acos(q/c3)/3.0;
        float s = cos(h);
        float t = sin(h)*sqrt(3.0);
        float rx = sqrt( -c*(s + t + 2.0) + m2 );
        float ry = sqrt( -c*(s - t + 2.0) + m2 );
        co = (ry+sign(l)*rx+abs(g)/(rx*ry)- m)/2.0;
    }
    else
    {
        float h = 2.0*m*n*sqrt( d );
        float s = sign(q+h)*pow(abs(q+h), 1.0/3.0);
        float u = sign(q-h)*pow(abs(q-h), 1.0/3.0);
        float rx = -s - u - c*4.0 + 2.0*m2;
        float ry = (s - u)*sqrt(3.0);
        float rm = sqrt( rx*rx + ry*ry );
        co = (ry/sqrt(rm-rx)+2.0*g/rm-m)/2.0;
    }
    vec2 r = ab * vec2(co, sqrt(1.0-co*co));
    return length(r-p) * sign(p.y-r.y);
}

float invs(float y) {
    return 0.5 - sin(asin(1.0-2.0*y)/3.0);
}

float isBetween(float a, float b, float c) {
    //float k = 3. / iResolution.y;
    return smoothstep(-0.5, 0., -mod(c-a, 2. * pi) + mod(b-a - 0.1 * pi, 2. * pi));
   //return exp( -1. * (abs(-mod(c-a, 2. * pi) + mod(b-a, 2. * pi))) );
}

float ellipse(vec2 uv, vec2 p, vec2 q, float i) {
    float quadTest = 0.5 * (sign(q.x - p.x) * sign(q.y - p.y) + 1.);
    i = 1.-quadTest;

    // center point
    vec2 c = (i == 1.) ? vec2(p.x, q.y)
                       : vec2(q.x, p.y);

    // axis distances between points
    float x = abs(q.x - p.x), y = abs(q.y - p.y);

    // ellipses (asymptotes when x==0 or y==0, annoying)
    //float d = (i == 1.) ? length((uv - c) * vec2(y/x,1)) - y
    //                    : length((uv - c) * vec2(1,x/y)) - x;

    float d = sdEllipse(uv - c, vec2(x, y));

    // (make this smoothstep or exp)
    // float s = smoothstep(-0.02, 0.02, -abs(d) + 0.01);
    float k = 1. / iResolution.y;
    float s = smoothstep(-k, k, -abs(d) + 0.006);
    s = exp(-100. * abs(d));
    // a, b angles from center to points
    // c angle from center to uv
    float a1 = atan(p.x-c.x, p.y-c.y);
    float a2 = atan(q.x-c.x, q.y-c.y); // move b from a-> b to "draw" thing
    float b = atan(uv.x-c.x, uv.y-c.y);

    // flip clockwise <-> anticlockwise across diagonal quads
    // float quadTest = 0.5 * (sign(q.x - p.x) * sign(q.y - p.y) + 1.);

    // cut out a1,a2 segment of ellipse
    float as = isBetween(a1, a2, b);
    return s;// * mix(as, 1. - as, quadTest);
}
void mainVR( out vec4 fragColor, in vec2 fragCoord, in vec3 ro, in vec3 rd )
{
	//get coords and direction
	vec3 dir=rd;
	vec3 from=ro;

	//volumetric rendering
	float s=0.1,fade=1.;
	vec3 v=vec3(0.);
	for (int r=0; r<volsteps; r++) {
		vec3 p=from+s*dir*.5;
		p = abs(vec3(tile)-mod(p,vec3(tile*2.))); // tiling fold
		float pa,a=pa=0.;
		for (int i=0; i<iterations; i++) {
			p=abs(p)/dot(p,p)-formuparam;
            p.xy*=mat2(cos(iTime*0.02),sin(iTime*0.02),-sin(iTime*0.02),cos(iTime*0.02));// the magic formula
			a+=abs(length(p)-pa); // absolute sum of average change
			pa=length(p);
		}
		float dm=max(0.,darkmatter-a*a*.001); //dark matter
		a*=a*a; // add contrast
		if (r>6) fade*=1.-dm; // dark matter, don't render near
		//v+=vec3(dm,dm*.5,0.);
		v+=fade;
		v+=vec3(s,s*s,s*s*s*s)*a*brightness*fade; // coloring based on distance
		fade*=distfading; // distance fading
		s+=stepsize;
	}
	v=mix(vec3(length(v)),v,saturation); //color adjust
	fragColor = vec4(v*.01,1.);
}
float happy_star(vec2 uv, float anim)
{
    uv = abs(uv);
    vec2 pos = min(uv.xy/uv.yx, anim);
    float p = (2.0 - pos.x - pos.y);
    return (2.0+p*(p*p-1.5)) / (uv.x+uv.y);
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
	//get coords and direction
	vec2 uv=fragCoord.xy/iResolution.xy-.5;
	uv.y*=iResolution.y/iResolution.x;
	vec3 dir=vec3(uv*zoom,1.);
	float time=iTime*speed+.25;

    uv *= 1.1 + 0.15 * cos(uv.y - 0.6 * iTime);
    uv.y += 0.02 * cos(iTime);

    // points
    vec2 p = 0.1 * vec2(cos(0.913 * iTime), sin(iTime));
    vec2 q = 0.2 * vec2(cos(0.81 * iTime), sin(0.73 * iTime));

    // should look bad if time gets too high
    float t = 10. * iTime + 8. * h21(uv) + 15. *exp(-0.01 * length(uv)) * (650. + iTime);
    int f = int(floor(t));

    float d = 10.;
    float s = 0.;
    vec2 pp = vec2(0.);

    vec3 e = vec3(1);
    vec3 col = vec3(0);

    float n = 20.;
    for (float i = 0.; i <= n; i++) {
        float f2 = 0.0001 * float(f);
        float f3 = 0.0001 * float(f + 1);

        vec2 qp = pp;

        pp = vec2( h21(vec2(f2)), h21(vec2(0.01 + f2)) );
        pp = pow(4. * pp * (1.-pp), vec2(4));

        vec2 pp2 = vec2( h21(vec2(f3)), h21(vec2(0.01 + f3)) );
        float fr = fract(t);
        fr = smoothstep(0., 1., fr); //idk if this changes anything
        pp = mix(pp, pp2, fr); // looks cool if you remove this too
        pp = 0.3 * (pp - 0.5);
        f++;
        //if(i>0.) d = length(uv-pp);sdSegment(uv, pp, qp);
        //s += exp(-40. * d);
        float s2;
        if (i > 0.) s2 = ellipse(uv, pp, qp, 0.);//mod(i, 2.));
        s = clamp(s + s2, 0., 1.);
        vec3 col2 = pal(i/n, e, e, e, (i/n) * vec3(0,1,2)/3.);
        col = mix(col, col2, s2);
    }

    col += 0.03;
    col += 0.35 * exp(-3. *length(uv));

	vec3 from=vec3(1.,.5,0.5);

	mainVR(fragColor, fragCoord, from, dir);
    fragColor*=vec4(col*3.,1.);
     uv *= 2.0 * ( cos(iTime * 2.0) -2.5); // scale
    float anim = sin(iTime * 12.0) * 0.1 + 1.0;  // anim between 0.9 - 1.1
    fragColor+= vec4(happy_star(uv, anim) * vec3(0.35,0.2,0.55)*0.1, 1.0);
}
