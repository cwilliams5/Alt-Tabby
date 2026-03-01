


float random (in vec2 p) {
    vec3 p3  = fract(vec3(p.xyx) * .1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float noise (in vec2 _st) {
    vec2 i = floor(_st);
    vec2 f = fract(_st);

    // Four corners in 2D of a tile
    float a = random(i);
    float b = random(i + vec2(1.0, 0.0));
    float c = random(i + vec2(0.0, 1.0));
    float d = random(i + vec2(1.0, 1.0));

    vec2 u = f * f * (3. - 2.0 * f);

    return mix(a, b, u.x) +
            (c - a)* u.y * (1. - u.x) +
            (d - b) * u.x * u.y;
}

float light(in vec2 pos,in float size,in float radius,in float inner_fade,in float outer_fade){
	float len = length(pos/size);
	return pow(clamp((1.0 - pow( clamp(len-radius,0.0,1.0) , 1.0/inner_fade)),0.0,1.0),1.0/outer_fade);
}


float flare(in float angle,in float alpha,in float time){
	float t = time;
    float n = noise(vec2(t+0.5+abs(angle)+pow(alpha,0.6),t-abs(angle)+pow(alpha+0.1,0.6))*7.0);

    float split = (15.0+sin(t*2.0+n*4.0+angle*20.0+alpha*1.0*n)*(.3+.5+alpha*.6*n));

    float rotate = sin(angle*20.0 + sin(angle*15.0+alpha*4.0+t*30.0+n*5.0+alpha*4.0))*(.5 + alpha*1.5);

    float g = pow((2.0+sin(split+n*1.5*alpha+rotate)*1.4)*n*4.0,n*(1.5-0.8*alpha));

    g *= alpha * alpha * alpha * .5;
	g += alpha*.7 + g * g * g;
	return g;
}

#define SIZE 3.8
#define RADIUS 0.15
#define INNER_FADE .08
#define OUTER_FADE 0.02
#define SPEED .21
#define BORDER 0.21

uniform float time;
uniform vec2 mouse;
uniform vec2 resolution;

#define time iTime
#define resolution iResolution.xy

vec2 project(vec2 position, vec2 a, vec2 b)
{
	vec2 q	 	= b - a;
	float u 	= dot(position - a, q)/dot(q, q);
	u 		= clamp(u, 0., 1.);
	return mix(a, b, u);
}

float segment(vec2 position, vec2 a, vec2 b)
{
	return distance(position, project(position, a, b));
}
float contour(float x)
{
	return 1.-clamp(x * 2048., 0., 1.);
}

float line(vec2 p, vec2 a, vec2 b)
{
	return contour(segment(p, a, b));
}

vec2 neighbor_offset(float i)
{
	float c = abs(i-2.);
	float s = abs(i-4.);
	return vec2(c > 1. ? c > 2. ? 1. : .0 : -1., s > 1. ? s > 2. ? -1. : .0 : 1.);
}
float happy_star(vec2 uv, float anim)
{
    uv = abs(uv);
    vec2 pos = min(uv.xy/uv.yx, anim);
    float p = (2.0 - pos.x - pos.y);
    return (2.0+p*(p*p-1.5)) / (uv.x+uv.y);
}

#define iterations 17
#define formuparam 0.53

#define volsteps 20
#define stepsize 0.1

#define zoom   0.800
#define tile   0.850
#define speed  0.010

#define brightness 0.0015
#define darkmatter 0.300
#define distfading 0.730
#define saturation 0.850

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = (fragCoord.xy - iResolution.xy * 0.5)/iResolution.y;
	float f = .0;
    float f2 = .0;



	vec3 dir=vec3(uv*zoom,1.);


	//mouse rotation

	vec3 from=vec3(1.,.5,0.5);


	//volumetric rendering
	float s2=0.1,fade=1.;
	vec3 v=vec3(0.);
	for (int r=0; r<volsteps; r++) {
		vec3 p=from+s2*dir*.5;
		p = abs(vec3(tile)-mod(p,vec3(tile*2.))); // tiling fold
		float pa,a=pa=0.;
		for (int i=0; i<iterations; i++) {
			p=abs(p)/dot(p,p)-formuparam;
            p.xy*=mat2(cos(iTime*0.05),sin(iTime*0.05),-sin(iTime*0.05),cos(iTime*0.05) );// the magic formula
			a+=abs(length(p)-pa); //
			pa=length(p);
		}
		float dm=max(0.,darkmatter-a*a*.001);
		a*=a*a; // add contrast
		if (r>6) fade*=1.-dm;

		v+=fade;
		v+=vec3(s2,s2*s2,s2*s2*s2*s2)*a*brightness*fade;
		fade*=distfading;
		s2+=stepsize;
	}
	v=mix(vec3(length(v)),v,saturation); //color adjust
	uv*=0.5;



	vec4 result		= vec4(0.,0.,0.,1.);

	float t2 		= abs(sin(time*.1));
	float c 		= cos(t2);
	float s 		= sin(t2);
	mat2 rm 		= mat2(c, s, -s, c);
	vec2 position		= vec2(0.,0.);
	for(float i = 0.; i < 256.; i++)
	{

		vec2 sample2		= neighbor_offset(mod(i, 8.))/resolution.y+position*rm;
		result 			+= line(uv, position, sample2);
		position		= sample2;
	}

    float t = iTime * SPEED;
	float alpha = light(uv,SIZE,RADIUS,INNER_FADE,OUTER_FADE);
	float angle = atan(uv.x,uv.y);
    float n = noise(vec2(uv.x*10.+iTime,uv.y*20.+iTime));

	float l = length(uv*v.xy*.01);
	if(l < BORDER){
        t *= .8;
        alpha = (1. - pow(((BORDER - l)/BORDER),0.22)*0.7);
        alpha = clamp(alpha-light(uv,0.02,0.0,0.3,.7)*.55,.0,1.);
        f = flare(angle*1.0,alpha,-t*.5+alpha);
        f2 = flare(angle*1.0,alpha*1.2,((-t+alpha*.5+0.38134)));


	}
		f = flare(angle,alpha,t)*1.3;

	fragColor = vec4(vec3(f*(1.0+sin(angle-t*4.)*.3)+f2*f2*f2,f*alpha+f2*f2*2.0,f*alpha*0.5+f2*(1.0+sin(angle+t*4.)*.3)),1.0);

       uv *= 2.0 * ( cos(iTime * 2.0) -2.5); // scale
    float anim = sin(iTime * 12.0) * 0.1 + 1.0;  // anim between 0.9 - 1.1
    fragColor*= vec4(happy_star(uv, anim) * vec3(0.55,0.5,1.15), 1.0);
    fragColor+= vec4(happy_star(uv, anim) * vec3(0.55,0.5,1.15)*0.01, 1.0);
}


