// cc by-sa-nc
// twitter: @LJ_1102
void mainImage(out vec4 c,vec2 f)
{
    vec2 w=iResolution.xy,p=f.xy/w.xy*2.-1.,o=p;
    p.x*=w.x/w.y;
    vec3 d=vec3(0);
    float t=iTime*.1,e=length(o),k=o.y+o.x,l,r,a;
    for(int i=0;i<40;i++)
        a=float(i),
        r=fract(sin(a*9.7))*.8,
        l=length(p=mod(p+vec2(sin(a+a-t),cos(t+a)+t*.1),2.)-1.),
        d+=pow(mix(vec3(.6,.46,.4),vec3(.25,.15,.3)+vec3(0,k,k)*.25,a/40.),vec3(3.))*(pow(max(1.-abs(l-r+e*.2),0.),25.)*.2+smoothstep(r,r-e*.2,l))
    ;
    c.rgb=sqrt(d)*1.4;
}
