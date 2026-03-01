// CC0: Reflective truchet
//  Quick work with simple lighting
//  Inspired by "UV Mapping Truchet Tiles" by byt3_m3chanic
//  https://www.shadertoy.com/view/NddGzH

#define ROT(a)      mat2(cos(a), sin(a), -sin(a), cos(a))

const float
  MaxDistance=30.
  // 3.8 makes it neon-style
, ColorOffset=.5
;

const vec3
  LD=normalize(vec3(1,2,-1))
, RO=vec3(0,0,-3)
, ColorBase=(ColorOffset+vec3(0,1,2))
;


mat2
  R0
, R1
;

float length4(vec2 p) {
  return sqrt(length(p*p));
}

// License: Unknown, author: Unknown, found: don't remember
vec3 hash(vec3 r)  {
  float h=fract(sin(dot(r.xy,vec2(1.38984*sin(r.z),1.13233*cos(r.z))))*653758.5453);
  return fract(h*vec3(1,3667,8667));
}

// License: MIT, author: Inigo Quilez, found: https://iquilezles.org/articles/distfunctions/
float torus(vec3 p) {
  const vec2 t=.5*vec2(1,.3);
  vec2 q = vec2(length(p.xz)-t.x,p.y);
  return length4(q)-t.y;
}

// License: MIT, author: Inigo Quilez, found: https://www.iquilezles.org/www/articles/smin/smin.htm
float pmin(float a, float b, float k) {
  float h = clamp(0.5+0.5*(b-a)/k, 0.0, 1.0);
  return mix(b, a, h) - k*h*(1.0-h);
}

float pmax(float a, float b, float k) {
  return -pmin(-a, -b, k);
}

float df(vec3 p) {
  float
    D
  , k
  , d
  , j
  ;

  vec3
    P
  , h
  , n
  ;

  D=length(p-RO)-.75;
  k=4./dot(p,p);
  p*=k;
  p.xz*=R0;
  p.xy*=R1;
  p.z-=.25*iTime;
  d=1e3;
  for(j=0.;j<2.;++j) {
    P=p+j*.5;
    n=floor(P+.5);
    h=hash(n+123.4);
    P-=n;
    P *=-1.+2.*step(h,vec3(.5));
    d=min(d,torus(P-vec3(.5,0,.5)));
    d=min(d,torus(P.yzx+vec3(.5,0,.5)));
    d=min(d,torus(P.yxz-vec3(.5,0,-.5)));
  }
  d/=k;
  d=pmax(d,-D,.5);

  return d;
}

vec3 normal(vec3 p) {
  vec2 e=vec2(1e-3,0);
  return normalize(vec3(
    df(p+e.xyy)-df(p-e.xyy)
  , df(p+e.yxy)-df(p-e.yxy)
  , df(p+e.yyx)-df(p-e.yyx)
  ));
}

float march(vec3 P, vec3 I) {
  float
    i
  , d
  , z=0.
  , nz=0.
  , nd=1e3
  ;

  for(i=0.;i<77.;++i) {
    d=df(z*I+P);
    if(d<1e-3||z>MaxDistance) break;
    if(d<nd) {
      nd=d;
      nz=z;
    }
    z+=d;
  }

  if(i==77.) {
    z=nz;
  }

  return z;
}

void mainImage(out vec4 O, vec2 C) {
  float
    i
  , f
  , z
  , A=1.
  ;

  vec2
    R=iResolution.xy
  ;

  vec3
    o=vec3(0)
  , c
  , p
  , n
  , r
  , P=RO
  , I=normalize(vec3(C-.5*R,R.y))
  ;

  R0=ROT(.213*.5*iTime);
  R1=ROT(.123*.5*iTime);

  for(i=0.;i<4.&&A>.07;++i) {
    c=vec3(0);
    z=march(P,I);
    p=z*I+P;
    n=normal(p);
    r=reflect(I,n);
    f=1.+dot(n,I);
    f*=f;
    if(z<MaxDistance)
      c+=pow(max(0.,dot(n,LD)),9.);
    o+=A*c*(1.1+sin(
        2.5*f+ColorBase));
    A*=mix(.3,.7,f);
    P=p+.05*n;
    I=r;
  }

  o*=3.;
  o=sqrt(o)-.07;
  o=max(o,0.);
  O=vec4(o,1);
}
