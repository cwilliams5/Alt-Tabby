
vec3 random3(vec3 c) {
	float j = 4096.0*sin(dot(c,vec3(17.0, 59.4, 15.0)));
	vec3 r;
	r.z = fract(512.0*j);
	j *= .125;
	r.x = fract(512.0*j);
	j *= .125;
	r.y = fract(512.0*j);
	return r-0.5;
}

/* skew constants for 3d simplex functions */
const float F3 =  0.3333333;
const float G3 =  0.1666667;

/* 3d simplex noise */
float simplex3d(vec3 p) {
	 /* 1. find current tetrahedron T and it's four vertices */
	 /* s, s+i1, s+i2, s+1.0 - absolute skewed (integer) coordinates of T vertices */
	 /* x, x1, x2, x3 - unskewed coordinates of p relative to each of T vertices*/

	 /* calculate s and x */
	 vec3 s = floor(p + dot(p, vec3(F3)));
	 vec3 x = p - s + dot(s, vec3(G3));

	 /* calculate i1 and i2 */
	 vec3 e = step(vec3(0.0), x - x.yzx);
	 vec3 i1 = e*(1.0 - e.zxy);
	 vec3 i2 = 1.0 - e.zxy*(1.0 - e);

	 /* x1, x2, x3 */
	 vec3 x1 = x - i1 + G3;
	 vec3 x2 = x - i2 + 2.0*G3;
	 vec3 x3 = x - 1.0 + 3.0*G3;

	 /* 2. find four surflets and store them in d */
	 vec4 w, d;

	 /* calculate surflet weights */
	 w.x = dot(x, x);
	 w.y = dot(x1, x1);
	 w.z = dot(x2, x2);
	 w.w = dot(x3, x3);

	 /* w fades from 0.6 at the center of the surflet to 0.0 at the margin */
	 w = max(0.6 - w, 0.0);

	 /* calculate surflet components */
	 d.x = dot(random3(s), x);
	 d.y = dot(random3(s + i1), x1);
	 d.z = dot(random3(s + i2), x2);
	 d.w = dot(random3(s + 1.0), x3);

	 /* multiply d by w^4 */
	 w *= w;
	 w *= w;
	 d *= w;

	 /* 3. return the sum of the four surflets */
	 return dot(d, vec4(52.0));
}


// The following two functions copied from The Book of Shaders
// Credit to: Patricio Gonzalez Vivo
float random (in vec2 st) {
    return fract(sin(dot(st.xy,
                         vec2(12.9898,78.233)))*
        43758.5453123);
}

// Based on Morgan McGuire @morgan3d
// https://www.shadertoy.com/view/4dS3Wd
float noise (in vec2 st) {
    vec2 i = floor(st);
    vec2 f = fract(st);

    // Four corners in 2D of a tile
    float a = random(i);
    float b = random(i + vec2(1.0, 0.0));
    float c = random(i + vec2(0.0, 1.0));
    float d = random(i + vec2(1.0, 1.0));

    vec2 u = f * f * (3.0 - 2.0 * f);

    return mix(a, b, u.x) +
            (c - a)* u.y * (1.0 - u.x) +
            (d - b) * u.x * u.y;
}

#define rotation(angle) mat2(cos(angle), -sin(angle), sin(angle), cos(angle));

float TAU = 2.*3.14159;
float PI = 3.14159;


// https://thebookofshaders.com/13/
float fbm (in vec2 p) {
    float nVal = 0.0;
    float amp = .45;
    int numOctaves = 4;
    for (int i = 0; i < numOctaves; i++) {
        nVal += amp * simplex3d(vec3(p,.2*iTime));
        nVal += amp * noise(p+iTime);
        p *= 3.;
        amp *= .45;
    }
    return nVal;
}

#define iterations 12
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

float happy_star(vec2 uv, float anim)
{
    uv = abs(uv);
    vec2 pos = min(uv.xy/uv.yx, anim);
    float p = (2.0 - pos.x - pos.y);
    return (2.0+p*(p*p-1.5)) / (uv.x+uv.y);
}
#define PI 3.141592
#define TWOPI 6.283184

#define R2D 180.0/PI*
#define D2R PI/180.0*

mat2 rotMat(in float r){float c = cos(r);float s = sin(r);return mat2(c,-s,s,c);}

//fract -> -0.5 -> ABS  : coordinate absolute Looping
float abs1d(in float x){return abs(fract(x)-0.5);}
vec2 abs2d(in vec2 v){return abs(fract(v)-0.5);}
float cos1d(float p){ return cos(p*TWOPI)*0.25+0.25;}
float sin1d(float p){ return sin(p*TWOPI)*0.25+0.25;}

#define OC 15.0
vec3 Oilnoise(in vec2 pos, in vec3 RGB)
{
    vec2 q = vec2(1.0);
    float result = 0.0;
    float t = iTime * .1 + ((.25 + .05 * sin(iTime * .1))/(length(pos.xy) + .07)) * 2.2;
	float si = sin(t);
	float co = cos(t);
	mat2 ma = mat2(co, si, -si, co);
    float s = 14.2;

    float gain = 0.44;
    vec2 aPos = abs2d(pos)*0.0;//add pos

    for(float i = 0.0; i < OC; i++)
    {
        pos *= rotMat(D2R 30.);

        float time = (sin(iTime)*0.5+0.5)*0.2+iTime*0.8;
        q =  pos * s + time;
        q =  pos * s + aPos + time;
        q = vec2(cos(q));
q*=ma;
        result += sin1d(dot(q, vec2(0.3))) * gain;

        s *= 1.07;
        aPos += cos(smoothstep(0.0,0.15,q));
        aPos*= rotMat(D2R 1.0);
        aPos*= 1.232;
    }

    result = pow(result,4.504);
    return clamp( RGB / abs1d(dot(q, vec2(-0.240,0.000)))*.5 / result, vec3(0.0), vec3(1.0));
}

#define resolution iResolution.xy
#define time iTime
void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
     vec2 uv = ( fragCoord - .5* iResolution.xy ) /iResolution.y;
    vec2 uv2 = ( fragCoord - .5* iResolution.xy ) /iResolution.y;
      vec2 uv3 = ( fragCoord - .5* iResolution.xy ) /iResolution.y;
      uv3.x+=0.5;
       uv3.y+=0.2;
    vec3 col = vec3(0.);
    float t = fract(iTime);
    //get coords and direction
	uv2.x+=0.1*cos(iTime);
    uv2.y+=0.1*sin(iTime);
	uv.y*=iResolution.y/iResolution.x;
	vec3 dir=vec3(uv*zoom,1.);
    vec2 uPos = ( gl_FragCoord.xy / resolution.y );//normalize wrt y axis
	uPos -= vec2((resolution.x/resolution.y)/2.0, 0.5);//shift origin to center

	float multiplier = 0.0005; // Grosseur
	const float step2 = 0.006; //segmentation
	const float loop = 80.0; //Longueur
	const float timeSCale = 0.5; // Vitesse

	vec3 blueGodColor = vec3(0.0);
	for(float i=1.0;i<loop;i++){
		float t = time*timeSCale-step2*i*i;
		vec2 point = vec2(0.75*sin(t), 0.5*sin(t));
		point += vec2(0.75*cos(t*4.0), 0.5*sin(t*3.0));
		point /= 11. * sin(i);
		float componentColor= multiplier/((uPos.x-point.x)*(uPos.x-point.x) + (uPos.y-point.y)*(uPos.y-point.y))/i;
		blueGodColor += vec3(componentColor/3.0, componentColor/3.0, componentColor);
	}


	vec3 color = vec3(0,0,0);
	color += pow(blueGodColor,vec3(0.1,0.3,0.8));

    vec3 from=vec3(1.,.5,0.5);
    vec2 uv0 = uv;
 vec3 col2 = vec3(0.0,0.0,0.0);
    vec2 st = (fragCoord/iResolution.xy);
            st.x = ((st.x - 0.5) *(iResolution.x / iResolution.y)) + 0.5;
    float stMask = step(0.0, st.x * (1.0-st.x));
 float t2 = iTime * .1 + ((.25 + .05 * sin(iTime * .1))/(length(uv3.xy) + .57)) * 25.2;
	float si = sin(t2);
	float co = cos(t2);
	mat2 ma = mat2(co, si, -si, co);

    //st-=.5; //st move centor. Oil noise sampling base to 0.0 coordinate
    st*=3.;

    vec3 rgb = vec3(0.30, .8, 1.200);


    //berelium, 2024-06-07 - anti-aliasing
    float AA = 1.0;
    vec2 pix = 1.0 / iResolution.xy;
    vec2 aaST = vec2(0.0);

    for(float i = 0.0; i < AA; i++)
    {
        for(float j = 0.0; j < AA; j++)
        {
            aaST = st + pix * vec2( (i+1.5)/AA, (j+0.5)/AA );
            col2 += Oilnoise(aaST, rgb);
        }

    }

    col2 /= AA * AA;
    float scale = 5.0;
    uv *= scale;
       uv2 *= 2.0 * ( cos(iTime * 2.0) -2.5); // scale
    float anim = sin(iTime * 12.0) * 0.1 + 1.0;  // anim between 0.9 - 1.1

    // Idea from IQ
    col += 3.*(fbm(uv + fbm(uv + fbm(uv))) - .4) * (1.5-length(uv0));

    col *= vec3(.9,.9,1.0);
    float s=0.1,fade=1.;
	vec3 v=vec3(0.);
	for (int r=0; r<volsteps; r++) {
		vec3 p=from+s*dir+.5;

		p = abs(vec3(tile)-mod(p,vec3(tile*2.))); // tiling fold
		float pa,a=pa=0.;
		for (int i=0; i<iterations; i++) {
			p=abs(p)/dot(p,p)-formuparam;
            p.xy*=mat2(cos(iTime*0.05), sin(iTime*0.05),-sin(iTime*0.05), cos(iTime*0.05));// the magic formula
			a+=abs(length(p)-pa); // absolute sum of average change
			pa=length(p);
		}
		float dm=max(0.,darkmatter-a*a*.001); //dark matter
		a*=a*a; // add contrast
		if (r>6) fade*=1.2-dm; // dark matter, don't render near
		//v+=vec3(dm,dm*.5,0.);
		v+=fade;
		v+=vec3(s,s*s,s*s*s*s)*a*brightness*fade; // coloring based on distance
		fade*=distfading; // distance fading
		s+=stepsize;
	}
	v=mix(vec3(length(v)),v,saturation); //color adjust





    	fragColor= vec4(v*.03+col+col2+color*2.,1.);
            fragColor+= vec4(happy_star(uv3*ma, anim) * vec3(0.15+0.1*cos(iTime),0.2,0.15+0.1*sin(iTime))*0.3, 1.0);
         fragColor+= vec4(happy_star(uv2, anim) * vec3(0.25+0.1*cos(iTime),0.2+0.1*sin(iTime),0.15)*0.5, 1.0);

           fragColor*= vec4(happy_star(uv2, anim) * vec3(0.25+0.1*cos(iTime),0.2+0.1*sin(iTime),0.15)*2., 1.0);
}