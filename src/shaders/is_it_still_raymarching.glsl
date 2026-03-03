//Inspired by https://www.shadertoy.com/view/MtX3Ws

#define aa
#define iTimer 0.
void mainImage(out vec4 fragColor, in vec2 fragCoord){
  vec2 r=iResolution.xy,m=iMouse.xy*6.28+3.14;
  float mr=1./min(r.x,r.y),x,y,i,j,c,f,t=iTime*1.,a=m.x,b=m.y;
  vec3 z,n,k,p,l=vec3(sin(t*.035),sin(t*.089)*cos(t*.073),cos(t*.1))*.3+vec3(.3);
  #ifdef aa
  for(;x++<2.;y=0.){for(;y++<2.;){
  #endif
    n=vec3((fragCoord*2.-r+vec2(x,y))*mr*4.,1.);
    vec3 g;float u=.2,d,e=1.;
    for(i=0.;i++<3.;){
      d+=u;p=n*d-l;c=0.;
      for(j=0.;j++<7.;){
        p=(sin(t*.05)*.1+.9)*abs(p)/dot(p,p)-(cos(t*.09)*.02+.8);
        p.xy=vec2(p.x*p.x-p.y*p.y,(smoothstep(0., 4., iTime)*3.+.8*cos(t*.07))*p.x*p.y);
        p=p.yxz;
        c+=exp(-9.*abs(dot(p,p.zxy)));
      }
      u*=exp(-c*.6);
      f=c*c*.09;
      g=g*1.5+.5*vec3(c*f*.3,f,f)*1.;
    }
    g*=g;
    k+=g*
    #ifdef aa
    .4;}}
    #else
    1.6;
    #endif
  fragColor=vec4(k/(1.+k),1.);
}
