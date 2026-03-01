/*
Author: Felipe Tovar-Henao [www.felipe-tovar-henao.com]
*/


#define PI 3.14159265359
#define TWO_PI 6.28318530718
#define FBM_ITER 5

vec2 viewport(in vec2 uv,in vec2 r){
	return(uv*2.-r)/min(r.x,r.y);
}

float rand(in float x,in int s){
    return fract(sin(x+float(s))*43758.5453123);
}

float rand(in vec2 uv,in int seed){
    return fract(sin(dot(uv.xy,vec2(12.9898,78.233))+float(seed))*43758.5453123);
}

float noise(in float x,in int s){
    float xi=floor(x);
    float xf=fract(x);
    return mix(rand(xi,s),rand(xi+1.,s),smoothstep(0.,1.,xf));
}

float noise(in vec2 p,in int s){
    vec2 pi=floor(p);
    vec2 pf=fract(p);

    vec2 o=vec2(0,1);

    float bl=rand(pi,s);
    float br=rand(pi+o.yx,s);
    float tl=rand(pi+o.xy,s);
    float tr=rand(pi+o.yy,s);

    vec2 w=smoothstep(0.,1.,pf);

    float t=mix(tl,tr,w.x);
    float b=mix(bl,br,w.x);

    return mix(b,t,w.y);
}

float fbm(in vec2 p,in int seed){
    float v=0.;
    float a=.5;
    float f=0.;
    for(int i=0;i<FBM_ITER;i++){
        v+=a*noise(p,seed);
        p*=2.;
        a*=.5;
    }
    return v;
}

vec3 gradient(in float t,in vec3 a,in vec3 b,in vec3 c,in vec3 d){
	return a+b*cos(TWO_PI*(c*t+d));
}

float cosine(in float x,in float s){
    float y=cos(fract(x)*PI);
    return floor(x)+.5-(.5*pow(abs(y),1./s)*sign(y));
}

float noise(in float x){
    return noise(x,0);
}

mat2 rot2(in float a){
    float c=cos(a);
    float s=sin(a);
    return mat2(c,-s,s,c);
}

float map(vec3 p){
	float t=iTime*.5;
	p.z+=t;
	t*=.125;
	float ti=floor(t);
	float tf=fract(t);
	float n=fbm(p.xz,0);
	n=pow(n,3.+sin(t));
	float g=p.y+2.;
	g-=n;
	g=min(g,3.3-g);
	return g;
}

const vec3 c3=vec3(.05);
const vec3 c4=vec3(.52,.57,.59);

void mainImage(out vec4 fragColor, in vec2 fragCoord){
	vec2 uv=viewport(fragCoord.xy,iResolution.xy);
	float t=iTime*.1;

	vec3 ro=vec3(0,0,-3);
	vec3 rd=normalize(vec3(uv,1));
    rd.xz *= rot2(sin(t));
	vec3 p=vec3(0);

	float d=0.;
	float dt=0.;

	float j=0.;

    float m=.1;
	float an=cos(t*.05)*m;

	for(int i=0;i<30;i++){
		p=ro+rd*d;
        p.xy*=rot2(d*an);
		dt=map(p);
		d+=dt;
		j=float(i);
		if(dt<.001||d>100.){
			break;
		}
	}


    float glow=sin(noise(t*5.))*.005+.02;
	d+=+j*(.33+glow*5.);
	float a=smoothstep(0.,30.,d);
	float phase=cosine(length(p.zy*.1),2.);

    float g=sin(iTime*.125)*.25+.35;
    vec3 c12=vec3(g);
	vec3 col1=gradient(phase,c12,c12,c3,c4)*d*.2;

    vec3 col2=mix(vec3(.9,.9,.56),vec3(.95,.65,.38),sin(noise(t*5.+uv.x*.3))*.5+.5)*d*glow;
	vec3 col=mix(col1,col2,a);

	fragColor=vec4(col,1.);
}
