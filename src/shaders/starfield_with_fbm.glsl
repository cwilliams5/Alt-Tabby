/*originals  sources https://www.shadertoy.com/view/lfVXRc
https://www.shadertoy.com/view/XlfGRj
https://www.shadertoy.com/view/mtyGWy
https://www.shadertoy.com/view/wdtczM
yes, this is a converted star nest again, but it turned out damn beautiful */

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

#define time iTime
#define resolution iResolution.xy
vec2 hash( vec2 p )
{
	p = vec2( dot(p,vec2(127.1,311.7)),
			 dot(p,vec2(175.,100.)) );
	return -1.0 + 2.0*fract(sin(p)*45000.0);
}

float noise( in vec2 p )
{
	const float K1 = 0.36;
	const float K2 = 0.22;


	vec2 i = floor( p + (p.x+p.y)*K1 );

	vec2 a = p - i + (i.x+i.y)*K2;
	vec2 o = (a.x>a.y) ? vec2(1.0,0.0) : vec2(0.0,1.0);
	vec2 b = a - o + K2;
	vec2 c = a - 1.0 + 2.0*K2;

	vec3 h = max( 0.5-vec3(dot(a,a), dot(b,b), dot(c,c) ), 0.0 );

	vec3 n = h*h*h*h*vec3( dot(a,hash(i+0.0)), dot(b,hash(i+o)), dot(c,hash(i+1.0)));

	return dot( n, vec3(70.0) );
}

float fbm(vec2 uv)
{
	float f;
	mat2 m = mat2( 1.6,  1.2, -1.2,  1.6 );
	f  = 0.5000*noise( uv ); uv = m*uv;
	f += 0.2500*noise( uv ); uv = m*uv;
	f += 0.1250*noise( uv ); uv = m*uv;
	f += 0.0625*noise( uv ); uv = m*uv;
	f = 0.5 + 0.5*f;

	return f;
}

mat2 rotate(float a)
{
	float c = cos(a*a);
	float s = sin(a);
	return mat2(c, s, -s, c);
}



float field2(in vec3 p, float s) {
	float strength = 7. + .03 * log(1.e-6 + fract(sin(time*10.) * 4500.0));
	float accum = s*3.;
	float prev = 0.;
	float tw = 0.;
	for (int i = 0; i < 12; ++i) {
		float mag = dot(p, p)*s;
		p = abs(p) / mag + vec3(-.9, -1.0, -1.);
		float w = exp(-float(i) / 9.);
		accum += w * exp(-strength * pow(abs(mag - prev), 2.2));
		tw += w;
		prev = mag;
	}
	return max(0., 5. * accum / tw - .8);
}


void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
	//get coords and direction
	vec2 uv=fragCoord.xy/iResolution.xy-.5;
	uv.y*=iResolution.y/iResolution.x;
	vec3 dir=vec3(uv*zoom,1.);


	//mouse rotation

	vec3 from=vec3(1.,.5,0.5);

  vec2 pos=(gl_FragCoord.xy/resolution.xy)*2.0-1.0;
	pos.x*=resolution.x/resolution.y;

	vec2 pos2=pos;
	pos2.y-=time*.10;
 vec4 o=fragColor;
     vec2 F = fragCoord;

	float s=fbm(pos2);

	float f=field2(vec3(pos,1.0),s/1.275);
	vec2 R = iResolution.xy;
    o-=o;
    for(float d,t = iTime*.01, i = 0. ; i > -1.; i -= .06 )
    {   d = fract( i -3.*t );
        vec4 c = vec4( ( F - R *.5 ) / R.y *d ,i,0 ) * 28.;
        for (int j=0 ; j++ <27; )
            c.xzyw = abs( c / dot(c,c)
                    -vec4( 7.-.2*sin(t) , 6.3 , .7 , 1.-cos(t/.8))/7.);
       o -= c * c.yzww  * d--*d  / vec4(1,4,1,1);
    }

	vec3 color=vec3(f*0.1, f*f*0.2, f*f*f*0.79+-0.3);


	//volumetric rendering
	float s2=0.1,fade=1.;
	vec3 v=vec3(0.);
	for (int r=0; r<volsteps; r++) {
		vec3 p=from+s*dir*.5+o.xyz;
		p = abs(vec3(tile)-mod(p,vec3(tile*2.)))+o.xyz; // tiling fold
		float pa,a=pa=0.;
		for (int i=0; i<iterations; i++) {
			p=abs(p)/dot(p,p)-formuparam;
            p.xy*=mat2(cos(iTime*0.05),sin(iTime*0.05),-sin(iTime*0.05),cos(iTime*0.05));// the magic formula
			a+=abs(length(p)-pa); // absolute sum of average change
			pa=length(p);
		}
		float dm=max(0.,darkmatter-a*a*.001); //dark matter
		a*=a*a; // add contrast
		if (r>6) fade*=1.2-dm*f; // dark matter, don't render near
		//v+=vec3(dm,dm*.5,0.);
		v+=fade;
		v+=vec3(s,s*f*s,s*s*s*s)*a*brightness*fade; // coloring based on distance
		fade*=distfading; // distance fading
		s+=stepsize;
	}
	v=mix(vec3(length(v)),v,saturation); //color adjust
	fragColor = vec4(v*.01*f,1.);


}
