//***************************************************************************************************
//
// Galvanize / Alcatraz
// Jochen "Virgill" Feldkoetter
//
// Intro for Nordlicht demoparty 2014      Shadertoy version
//
//***************************************************************************************************



int efx = 0;
int refleco = 0;
int snowo = 0;
vec4 orbitTrap = vec4(0.0);
float blend =0.0;
float d = 0.0;
float m = 0.0;
float kalitime =0.;
float depth = 0.;
float prec =0.;
const float scene = 35.;


// Rotate
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


// noise functions
float rand1(vec2 co)
{
    return fract(sin(dot(co.xy ,vec2(12.9898,78.233))) * 43758.5453);
}

float rand2(vec2 co)
{
    return fract(cos(dot(co.xy ,vec2(12.9898,78.233))) * 43758.5453);
}




// polyomial smooth min (IQ)
float sminPoly( float a, float b, float k )
{
    float h = clamp( 0.5+0.5*(b-a)/k, 0.0, 1.0 );
    return mix( b, a, h ) - k*h*(1.0-h);
}


// exponential smooth min (IQ)
float smin( float a, float b, float k )
{
    float res = exp( -k*a ) + exp( -k*b );
    return -log( res )/k;
}


// length
float length2(vec2 p)
{
  	return dot(p, p);
}

// worley effect
float worley(vec2 p)
{
	float d = 1.;
	for (int xo = -1; xo <= 1; ++xo)
	for (int yo = -1; yo <= 1; ++yo)
    {
		vec2 tp = floor(p) + vec2(xo, yo);
		d = min(d, length2(p - tp - vec2(rand1(tp))));
	}
	return 3.*exp(-4.*abs(2.*d - 1.));
}

float fworley(vec2 p)
{
	return sqrt(sqrt(sqrt(worley(p*32. + 4.3 + iTime*.250) * sqrt(worley(p * 64. + 5.3 + iTime * -.125)) * sqrt(sqrt(worley(p * -128. +7.3))))));
}


// menger
float NewMenger(vec3 z)
{
	float Scale = 3.0;
	vec3 Offset = vec3(1.0,1.0,1.0);
	int Iterations = 6;
	int ColorIterations = 3;

    for(int n = 0; n < 6; n++)
	{
	z.z*=1.+0.2*sin(iTime/4.0)+0.1;
		z = abs(z);
		if (z.x<z.y){ z.xy = z.yx;}
		if (z.x< z.z){ z.xz = z.zx;}
		if (z.y<z.z){ z.yz = z.zy;}
		z = Scale*z-Offset*(Scale-1.0);
		if( z.z<-0.5*Offset.z*(Scale-1.0))  z.z+=Offset.z*(Scale-1.0);

		if (n<ColorIterations) orbitTrap = min(orbitTrap, (vec4(abs(z),dot(z,z))));

	}
	return abs(length(z) ) * pow(Scale, float(-Iterations-1));
}



// mandelbulb (Fractalforums.com)
float Mandelbulb(vec3 p)
{
	float Scale = 3.0;
	int Iterations = 6;
	int ColorIterations = 1;
	float parachute=(1.-min(1.8*abs(sin((iTime-5.0)*3.1415/scene)),1.0)); // Fallschirm
	parachute = smoothstep(0.0,1.0,parachute)*35.0;
	vec3 w = p;
	float dr = 1.0+parachute;
	float r = 0.;
    for (int i=0; i<6; ++i)
	{
    	r = length(w);
		if (r>4.0) break;
		dr*=pow(r, 7.)*8.+1.;
		float x = w.x; float x2 = x*x; float x4 = x2*x2;
		float y = w.y; float y2 = y*y; float y4 = y2*y2;
		float z = w.z; float z2 = z*z; float z4 = z2*z2;
		float k3 = x2 + z2;
		float k2 = inversesqrt( pow(k3, 7.0) );
		float k1 = x4 + y4 + z4 - 6.0*y2*z2 - 6.0*x2*y2 + 2.0*z2*x2;
		float k4 = x2 - y2 + z2;
		w =  vec3(64.0*x*y*z*(x2-z2)*k4*(x4-6.0*x2*z2+z4)*k1*k2,-16.0*y2*k3*k4*k4 + k1*k1,-8.0*y*k4*(x4*x4 - 28.0*x4*x2*z2 + 70.0*x4*z4 - 28.0*x2*z2*z4 + z4*z4)*k1*k2);
		w-=p;
		w = rotYaxis(w,sin(iTime*0.14));
		w = rotZaxis(w,cos(iTime*0.2));
		orbitTrap = min(orbitTrap, abs(vec4(p.x*w.z, p.y*w.x, 0., 0.)));
		if (i>=ColorIterations+2) orbitTrap = vec4(0.0);
	}
	return  .5*log(r)*r/dr;
}

// kalibox (Kali / Fractalforums.com)
float Kalibox(vec3 pos)
{
	float Scale = 1.84;
	int Iterations = 14;
	int ColorIterations = 3;
	float MinRad2 = 0.34;
	vec3 Trans = vec3(0.076,-1.86,0.036);
	vec3 Julia = vec3(-0.66,-1.2+(kalitime/80.),-0.66);
	vec4 scale = vec4(Scale, Scale, Scale, abs(Scale)) / MinRad2;
	float absScalem1 = abs(Scale - 1.0);
	float AbsScaleRaisedTo1mIters = pow(abs(Scale), float(1-Iterations));
    vec4 p = vec4(pos,1), p0 = vec4(Julia,1);
	for (int i=0; i<14; i++)
		{
			p.xyz=abs(p.xyz)+Trans;
			float r2 = dot(p.xyz, p.xyz);
			p *= clamp(max(MinRad2/r2, MinRad2), 0.0, 1.0);
			p = p*scale + p0;
			if (i<ColorIterations) orbitTrap = min(orbitTrap, abs(vec4(p.xyz,r2)));
		}
		return (    (length(p.xyz) - absScalem1) / p.w - AbsScaleRaisedTo1mIters    );
}

// balls and cube
float Balls(vec3 pos)
{
	m = length(max(abs(rotYaxis(rotXaxis(pos+vec3(0.0,-0.3,0.0),iTime),iTime*0.3))-vec3(0.35,0.35,0.35),0.0))-0.02;
	m = smin (m, length(pos+vec3(0.0,-0.40,1.2+0.5*sin(0.8*iTime+0.0)))-0.4,7.4);
	m = smin (m, length(pos+vec3(0.0,-0.40,-1.2-0.5*sin(0.8*iTime+0.4)))-0.4,7.4);
	m = smin (m, length(pos+vec3(-1.2-0.5*sin(0.8*iTime+0.8),-0.40,0.0))-0.4,7.4);
	m = smin (m, length(pos+vec3(1.2+0.5*sin(0.8*iTime+1.2),-0.40,0.0))-0.4,7.4);
	m = smin (m, length(pos+vec3(0.0,-1.6+0.5*-sin(0.8*iTime+1.6),0.0))-0.4,7.4);
	//m+= klang1*(0.003*cos(50.*pos.x)+0.003*cos(50.*pos.y)); //distortion
	orbitTrap = vec4(length(pos)-0.8*pos.z,length(pos)-0.8*pos.y,length(pos)-0.8*pos.x,0.0)*1.0;
	return m;
}

// plane
float sdPlane(in vec3 p)
{
	return p.y+(0.025*sin(p.x*10.  +1.4*iTime  ))+(0.025*sin(p.z*12.3*cos(0.4-p.x)+  1.6*iTime  ))-0.05;
}

// cylinder
float sdCylinder( vec3 p, vec3 c )
{
	return length(p.xz-c.xy)-c.z;
}


// scene
float map(in vec3 p)
{
	orbitTrap = vec4(10.0);
	d = sdPlane(p);

	if (efx == 0) {			// balls and cube
	m = Balls(p);
	}
	if (efx == 1) {			// milky menger
	m = NewMenger(rotYaxis(rotXaxis(p-vec3(0.0,sin(iTime/0.63)+0.2,0.0),0.15*iTime),0.24*iTime));
	}
	if (efx == 2) {			// mandelbulb
	m = Mandelbulb(rotYaxis(rotXaxis(p,iTime*0.1),0.21*iTime));
	}
	if (efx == 3) {			// kalibox
	m = Kalibox(rotYaxis(rotXaxis(p,1.50),0.1*iTime));
	}
	if (efx == 4 || efx == 5) { // tunnel or swirl
	vec3 c = vec3(2.0, 8.0, 2.0);
	vec3 q = mod(p-vec3(1.0,0.1*iTime,1.0),c)-0.5*c;
	float kali = Kalibox(rotYaxis(q,0.04*iTime));
	m = max(kali,-sdCylinder(p,vec3(0.0,0.0,0.30+0.1*sin(iTime*0.2))) );
	}
	d = sminPoly (m, d, 0.04);
   	return d;
}


// normal calculation
vec3 calcNormal(in vec3 p)
{
    vec3 e = vec3(0.001, 0.0, 0.0);
    vec3 nor = vec3(map(p + e.xyy) - map(p - e.xyy),  map(p + e.yxy) - map(p - e.yxy),  map(p + e.yyx) - map(p - e.yyx));
    return normalize(nor);
}

// cast
float castRay(in vec3 ro, in vec3 rd, in float maxt)
{
    float precis = prec;
    float h = precis * 2.0;
    float t = depth;

    for(int i = 0; i < 122; i++)
	{
        if(abs(h) < precis || t > maxt) break;
        orbitTrap = vec4(10.0);
		h = map(ro + rd * t);
        t += h;
	}
    return t;
}

// softshadow (IQ)
float softshadow(in vec3 ro, in vec3 rd, in float mint, in float maxt, in float k)
{
    float sh = 1.0;
    float t = mint;
    float h = 0.0;
    for(int i = 0; i < 19; i++)  //23 gut!
	{
        if(t > maxt) continue;
		orbitTrap = vec4(10.0);
        h = map(ro + rd * t);
        sh = min(sh, k * h / t);
        t += h;
    }
    return sh;
}


// orbit color
vec3 BaseColor = vec3(0.2,0.2,0.2);
vec3 OrbitStrength = vec3(0.8, 0.8, 0.8);
vec4 X = vec4(0.5, 0.6, 0.6, 0.2);
vec4 Y = vec4(1.0, 0.5, 0.1, 0.7);
vec4 Z = vec4(0.8, 0.7, 1.0, 0.3);
vec4 R = vec4(0.7, 0.7, 0.5, 0.1);
vec3 getColor()
{
	orbitTrap.w = sqrt(orbitTrap.w);
	vec3 orbitColor = X.xyz*X.w*orbitTrap.x + Y.xyz*Y.w*orbitTrap.y + Z.xyz*Z.w*orbitTrap.z + R.xyz*R.w*orbitTrap.w;
	vec3 color = mix(BaseColor,3.0*orbitColor,OrbitStrength);
	return color;
}

// particles (Andrew Baldwin)
float snow(vec3 direction)
{
	float help = 0.0;
	const mat3 p = mat3(13.323122,23.5112,21.71123,21.1212,28.7312,11.9312,21.8112,14.7212,61.3934);
	vec2 uvx = vec2(direction.x,direction.z)+vec2(1.,iResolution.y/iResolution.x)*gl_FragCoord.xy / iResolution.xy;
	float acc = 0.0;
	float DEPTH = direction.y*direction.y-0.3;
	float WIDTH =0.1;
	float SPEED = 0.1;
	for (int i=0;i<10;i++)
	{
		float fi = float(i);
		vec2 q = uvx*(1.+fi*DEPTH);
		q += vec2(q.y*(WIDTH*mod(fi*7.238917,1.)-WIDTH*.5),SPEED*iTime/(1.+fi*DEPTH*.03));
		vec3 n = vec3(floor(q),31.189+fi);
		vec3 m = floor(n)*.00001 + fract(n);
		vec3 mp = (31415.9+m)/fract(p*m);
		vec3 r = fract(mp);
		vec2 s = abs(mod(q,1.)-.5+.9*r.xy-.45);
		float d = .7*max(s.x-s.y,s.x+s.y)+max(s.x,s.y)-.01;
		float edge = .04;
		acc += smoothstep(edge,-edge,d)*(r.x/1.0);
		help = acc;
	}
	return help;
	}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{

    if (iTime >=0. && iTime <=35. ) {efx=4; refleco=0; snowo=0;}
    if (iTime >35. && iTime <=70. ) {efx=0; refleco=1; snowo=1;}
    if (iTime >70. && iTime <=105.) {efx=1; refleco=0; snowo=1;}
    if (iTime >105.&& iTime <=140.) {efx=3; refleco=0; snowo=1;}
    if (iTime >140.&& iTime <=175.) {efx=2; refleco=0; snowo=1;}
    if (iTime >175.&& iTime <=210.) {efx=4; refleco=0; snowo=0;}
    if (iTime >210.&& iTime <=245.) {efx=5; refleco=0; snowo=0;}

	blend=min(2.0*abs(sin((iTime+0.0)*3.1415/scene)),1.0);
    if (iTime >245.) blend = 0.;
    vec2 uv = fragCoord.xy / iResolution.xy;
    vec2 p = uv * 2.0 - 1.0;
	p.x *= iResolution.x / iResolution.y;
	float theta = sin(iTime*0.03) * 3.14 * 2.0;
    float x = 3.0 * cos(theta)+0.007*rand1(fragCoord.xy);
    float z = 3.0 * sin(theta)+0.007*rand2(fragCoord.xy);
	vec3 ro; // camera

	if (efx==0) {
	prec = 0.001;
	ro = vec3(x*0.2+1.0, 5.0, z*2.0-3.); 	// camera balls and cube
	}
	if (efx==1) {
	prec = 0.002;
	ro = vec3(x*1.2, 7.0, z*2.0);  			// camera menger
	}
	if (efx==2) {
	prec = 0.002;
	ro = vec3(x*1.0, 6.2, z*2.8);  			// camera mandelbulb
	depth =4.;
	}
	if (efx==3) {
	kalitime = 40.;
	prec = 0.002;
	ro = vec3(x*1.7, 2.6, 2.0);	 			// camera kalibox
	}
	if (efx==4) {
	//time = iTime -2.5;
	prec = 0.002;
	kalitime = iTime-15.0;
	ro = vec3(0.0, 8.0, 0.0001);   			// camera tunnel
	}
	if (efx==5) {
	prec = 0.004;
	kalitime = 210.+175.;
	ro = vec3(0, 3.8, 0.0001);   			// camera swirl
	}


	vec3 ta = vec3(0.0, 0.25, 0.0);
    vec3 cw = normalize(ta - ro);
    vec3 cp = vec3(0.0, 1.0, 0.0);
    vec3 cu = normalize(cross(cw, cp));
    vec3 cv = normalize(cross(cu, cw));
	vec3 rd = normalize(p.x * cu + p.y * cv + 7.5 * cw);

// render:
    vec3 col = vec3(0.0);
    float t = castRay(ro, rd, 12.0);
	vec3 pos = ro + rd *t;
	vec3 nor = calcNormal(pos);
	vec3 lig;
	if (efx==4 || efx ==5 )  	lig = normalize(vec3(-0.4*sin(iTime*0.15), 1.0, 0.5));
	else if (efx==3)		  	lig = normalize(vec3(-0.1*sin(iTime*0.2), 0.2, 0.4*sin(iTime*0.1)));
	else 						lig = normalize(vec3(-0.4, 0.7, 0.5));
	float dif = clamp(dot(lig, nor), 0.0, 1.0);
	float spec = pow(clamp(dot(reflect(rd, nor), lig), 0.0, 1.0), 16.0);
	float sh;
	if (efx == 1 || efx == 5) sh = softshadow(pos, lig, 0.02, 20.0, 7.0);
	vec3 color = getColor();
	col = ((0.8*dif+ spec) + 0.35*color);
	if (efx !=1 && efx != 5) sh = softshadow(pos, lig, 0.02, 20.0, 7.0);
	col = col*clamp(sh, 0.0, 1.0);


// reflections:
if (refleco == 1) {
    vec3 col2 = vec3(0.0);
	vec3 ro2 = pos-rd/t;
	vec3 rd2 = reflect(rd,nor);
    float t2 = castRay(ro2, rd2, 7.0);
	vec3 pos2 = vec3(0.0);
	if (t2<7.0) {
	pos2 = ro2 + rd2* t2;
	}
    vec3 nor2 = calcNormal(pos2);
	float dif2 = clamp(dot(lig, nor2), 0.0, 1.0);
	float spec2 = pow(clamp(dot(reflect(rd2, nor2), lig), 0.0, 1.0), 16.0);
	col+= 0.22*vec3(dif2*color+spec2);
}

// postprocessing
float klang1=0.75;
vec2 uv2=-0.3+2.*fragCoord.xy/iResolution.xy;
col-=0.20*(1.-klang1)*rand1(uv2.xy*iTime);
col*=.9+0.20*(1.-klang1)*sin(10.*iTime+uv2.x*iResolution.x);
col*=.9+0.20*(1.-klang1)*sin(10.*iTime+uv2.y*iResolution.y);
float Scr=1.-dot(uv2,uv2)*0.15;
vec2 uv3=fragCoord.xy/iResolution.xy;
float worl = fworley(uv3 * iResolution.xy / 2100.);
worl *= exp(-length2(abs(2.*uv3 - 1.)));
worl *= abs(1.-0.6*dot(2.*uv3-1.,2.*uv3-1.));
if (efx==4) col += vec3(0.4*worl,0.35*worl,0.25*worl);
if (efx==5)  col += vec3(0.2*worl);
float g2 = (blend/2.)+0.39;
float g1 = ((1.-blend)/2.);
if (uv3.y >=g2+0.11) col*=0.0;
if (uv3.y >=g2+0.09) col*=0.4;
if (uv3.y >=g2+0.07) {if (mod(uv3.x-0.06*iTime,0.18)<=0.16) col*=0.5;}
if (uv3.y >=g2+0.05) {if (mod(uv3.x-0.04*iTime,0.12)<=0.10) col*=0.6;}
if (uv3.y >=g2+0.03) {if (mod(uv3.x-0.02*iTime,0.08)<=0.06) col*=0.7;}
if (uv3.y >=g2+0.01) {if (mod(uv3.x-0.01*iTime,0.04)<=0.02) col*=0.8;}
if (uv3.y <=g1+0.10) {if (mod(uv3.x+0.01*iTime,0.04)<=0.02) col*=0.8;}
if (uv3.y <=g1+0.08) {if (mod(uv3.x+0.02*iTime,0.08)<=0.06) col*=0.7;}
if (uv3.y <=g1+0.06) {if (mod(uv3.x+0.04*iTime,0.12)<=0.10) col*=0.6;}
if (uv3.y <=g1+0.04) {if (mod(uv3.x+0.06*iTime,0.18)<=0.16) col*=0.5;}
if (uv3.y <=g1+0.02) col*=0.4;
if (uv3.y <=g1+0.00) col*=0.0;

if (snowo == 1) fragColor = (vec4(col*1.0*Scr-1.6*snow(cv), 1.0)*blend)*vec4(1.0, 0.93, 1.0, 1.0);
else fragColor = vec4(col*1.0*Scr, 1.0)*blend;
}


