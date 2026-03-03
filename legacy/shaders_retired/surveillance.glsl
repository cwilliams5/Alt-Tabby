//**********************************************************************************
// dusty menger scene from my 4k intro Surveillance
// Virgill 2016
// https://www.youtube.com/watch?v=kiE2c06EzBQ
// http://www.pouet.net/prod.php?which=67120
//**********************************************************************************

// circle of confusion idea by eiffie
// more interesting menger by shane
float focalDistance=20.;
float aperature=.04;
float fudgeFactor=.9;
float shadowCone=.5;
vec4 orbitTrap = vec4(0.);
float blend =0.;
float d = 0.;
float m = 0.;
vec3 pcoc = vec3(0.);
float rCoC,h;
vec4 col=vec4(0.);
float pixelSize;

// coc (eiffie)
float CircleOfConfusion(float t)
{
return max(abs(focalDistance-t)*aperature,pixelSize*(1.0+t));
}

// linestep (knighty)
float linstep(float a, float b, float t)
{
    float v=(t-a)/(b-a);
    return clamp(v,0.,1.);
}

vec3 rotXaxis(vec3 p, float rad)
{
	float z2 = cos(rad) * p.z - sin(rad) * p.y;
	float y2 = sin(rad) * p.z + cos(rad) * p.y;
	p.z = z2;
	p.y = y2;
	return p;
}

vec3 rotYaxis(vec3 p, float rad)
{
	float x2 = cos(rad) * p.x - sin(rad) * p.z;
	float z2 = sin(rad) * p.x + cos(rad) * p.z;
	p.x = x2;
	p.z = z2;
	return p;
}

vec3 rotZaxis(vec3 p, float rad)
{
	float x2 = cos(rad) * p.x - sin(rad) * p.y;
	float y2 = sin(rad) * p.x + cos(rad) * p.y;
	p.x = x2;
	p.y = y2;
	return p;
}

float rand1(vec2 co)
{
    return fract(sin(dot(co.xy ,vec2(12.9898,78.233))) * 43758.5453);
}


// new and interesting menger formula (shane)
float NewMenger(vec3 q)
{
 	vec3 p = abs(fract(q/3.)*3. - 1.5);
 	float d = min(max(p.x, p.y), min(max(p.y, p.z), max(p.x, p.z))) - 1. + .05;
    p =  abs(fract(q) - .5);
 	d = max(d, min(max(p.x, p.y), min(max(p.y, p.z), max(p.x, p.z))) - 1./3. + .05);
    p =  abs(fract(q*2.)*.5 - .25);
 	d = max(d, min(max(p.x, p.y), min(max(p.y, p.z), max(p.x, p.z))) - .5/3. - .015);
    p =  abs(fract(q*3./.5)*.5/3. - .5/6.);
 	return max(d, min(max(p.x, p.y), min(max(p.y, p.z), max(p.x, p.z))) - 1./18. - .015);
}


//***************************************************************************************************
// MAP
//***************************************************************************************************

float map(in vec3 p)
{
	orbitTrap = vec4(length(p)-0.8*p.z,length(p)-0.8*p.y,length(p)-0.8*p.x,0.0)*1.0;
	return NewMenger(p);
}


//***************************************************************************************************
// fuzzy shadow
//***************************************************************************************************

const float ShadowContrast = 0.99;
float FuzzyShadow(vec3 ro, vec3 rd, float coneGrad, float rCoC){
	float  t=rCoC*2.0,s=1.0;
	for(int i=0;i<9;i++)
	{
		if(s<0.1)continue;
		float r=rCoC+t*coneGrad+0.05;
		float d=map(ro+rd*t)+r*0.6;
		s*=linstep(-r,r,d);
		t+=abs(d)*(0.8+0.2*rand1(gl_FragCoord.xy*vec2(i)));
	}
	return clamp(s*ShadowContrast+(1.0-ShadowContrast),0.0,1.0);
}


//***************************************************************************************************
// Orbit color
//***************************************************************************************************

float Cycles = 4.0;
vec3 cycle(vec3 c, float s)
{
	return vec3(0.5)+0.5*vec3(cos(s*Cycles+c.x),cos(s*Cycles+c.y),cos(s*Cycles+c.z));
}

vec3 BaseColor = vec3(0.2,0.2,0.2);
vec3 OrbitStrength = vec3(0.8, 0.8, 0.8);
vec4 X = vec4(0.6, 0.5, 0.6, 0.2);
vec4 Y = vec4(1.0, 0.5, 0.1, 0.7);
vec4 Z = vec4(0.7, 0.8, 1.0, 0.3);
vec4 R = vec4(0.7, 0.7, 0.5, 0.1);

vec3 getColor()
{
	orbitTrap.w = sqrt(orbitTrap.w);
	vec3 orbitColor = cycle(X.xyz,orbitTrap.x)*X.w*orbitTrap.x + cycle(Y.xyz,orbitTrap.y)*Y.w*orbitTrap.y + cycle(Z.xyz,orbitTrap.z)*Z.w*orbitTrap.z + cycle(R.xyz,orbitTrap.w)*R.w*orbitTrap.w;
	vec3 color = mix(BaseColor, 3.0*orbitColor,  OrbitStrength);
	return color;
}



//***************************************************************************************************
// Cast ray
//***************************************************************************************************

// coc (eiffie)
void castRay(in vec3 ro, in vec3 rd)
{
	vec3 lig = normalize(vec3(0.4+cos((25.+iTime)*0.33), 0.2, 0.6));
    float t = 0.;
    for (int i = 0; i < 70; i++)
	{
		if(col.w>0.999 ||t>15.0)continue;
		rCoC=CircleOfConfusion(t);
		h = map(ro)+0.5*rCoC;
		if(h<rCoC)
		{
			pcoc=ro-rd*abs(h-rCoC);
			vec2 v=vec2(rCoC*0.5,0.0);
			vec3 N=normalize(vec3(-map(pcoc-v.xyy)+map(pcoc+v.xyy),-map(pcoc-v.yxy)+map(pcoc+v.yxy),-map(pcoc-v.yyx)+map(pcoc+v.yyx)));
			vec3 scol=2.3*getColor();
			float newdiff = clamp(dot(lig, N), 0.0, 1.0);
			float newspec = pow(clamp(dot(reflect(rd, N), lig), 0.0, 1.0), 16.0);
			float newsh   = FuzzyShadow(pcoc,lig,shadowCone,rCoC+0.00);
			scol *= 0.5*newdiff+newspec;
		 	scol *= newsh;
			float alpha=(1.0-col.w)*linstep(-rCoC,rCoC,-h*1.7);
			col+=vec4(scol*alpha,alpha);
		}
		h=abs(fudgeFactor*h*(0.3+0.05*rand1(gl_FragCoord.xy*vec2(i))));
		ro+=h*rd;
		t += h;
	}
}

//***************************************************************************************************
// main
//***************************************************************************************************

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
	focalDistance=6.5+3.*cos((25.+iTime)*0.133);
	pixelSize=1.0/iResolution.y;
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
	vec2 p = uv * 2.0 - 1.0;
    vec3 rd = (vec3(2.*fragCoord - iResolution.xy, iResolution.y));
    rd = normalize(vec3(rd.xy, sqrt(max(rd.z*rd.z - dot(rd.xy, rd.xy)*.2, 0.))));
    vec2 m = sin(vec2(0, 1.57079632) + (25.+iTime)/4.);
    rd.xy = mat2(m.y, -m.x, m)*rd.xy;
    rd.xz = mat2(m.y, -m.x, m)*rd.xz;
    vec3 ro = vec3(0.0, 2.0, 5.+sin((25.+iTime)/2.));

	castRay(ro, rd);

	vec2 uv2=-0.3+2.*gl_FragCoord.xy/iResolution.xy;
	//anti branding noise
    col-=0.10*rand1(uv2.xy*iTime);


	fragColor = col*0.7;
}
