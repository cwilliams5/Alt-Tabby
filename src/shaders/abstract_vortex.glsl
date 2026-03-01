// Shader by Frostbyte
// Licensed under CC BY-NC-SA 4.0

/*
Only 10 Raymarch Steps! Other looks can be found with as few as 5 steps.
This shader was influenced by Xor's Surf 2, but created using a different technique.
Xor's Surf 2: https://www.shadertoy.com/view/3fKSzc
Methods were drawn from my Abstract Series: https://www.shadertoy.com/playlist/D3VBDt
In this series, I aimed for creativity with low raymarch count volumetrics.
Many looks can be found with a few adjustments but the low ray march count makes it tricky and interesting.
One of the challenges is creating depth with the lower raymarch count.
Accumulated glow/HDR is reduced. Less steps are taken along z and the distance along z is reduced.
Ways I added percieved depth here is through movement, turbulence,
color contrast of background, volumetric glow, and color variation along length(p.xy).

Notes:
Aces tonemap > Tanh for higher contrast look in this scene.
Dot noise - volume that we are moving through.
Clear Tunnel for "Camera": 2.-length(p.xy)
Turbulent Effect: s+=abs(sin(p.z)); - Movement along z creates turbulent effect
Color like "Luminence": 1.+sin(i))/s; - s gives glow and sin(i) gives iterative color for each raymarch
Volumetrics: p+=d*s; Accumulate along each step of d
*/

//2d rotation matrix
vec2 r(vec2 v,float t){float s=sin(t),c=cos(t);return mat2(c,-s,s,c)*v;}

// ACES tonemap: https://www.shadertoy.com/view/Xc3yzM
vec3 a(vec3 c)
{
mat3 m1=mat3(0.59719,0.07600,0.02840,0.35458,0.90834,0.13383,0.04823,0.01566,0.83777);
mat3 m2=mat3(1.60475,-0.10208,-0.00327,-0.53108,1.10813,-0.07276,-0.07367,-0.00605,1.07602);
vec3 v=m1*c,a=v*(v+0.0245786)-0.000090537,b=v*(0.983729*v+0.4329510)+0.238081;
return m2*(a/b);
}

//Xor's Dot Noise: https://www.shadertoy.com/view/wfsyRX
float n(vec3 p)
{
    const float PHI = 1.618033988;
    const mat3 GOLD = mat3(
    -0.571464913, +0.814921382, +0.096597072,
    -0.278044873, -0.303026659, +0.911518454,
    +0.772087367, +0.494042493, +0.399753815);
    return dot(cos(GOLD * p), sin(PHI * p * GOLD));
}

void mainImage(out vec4 o,in vec2 u){
    float i,s,t=iTime;
    vec3 p,l,b,d;p.z=t;
    d=normalize(vec3(2.*u-iResolution.xy,iResolution.y));
    for(o*=i;i<10.;i++){
        b=p;
        b.xy=r(sin(b.xy),t*1.5+b.z*3.);
        s=.001+abs(n(b*12.)/12.-n(b))*.4;
        s=max(s,2.-length(p.xy));
        s+=abs(p.y*.75+sin(p.z+t*.1+p.x*1.5))*.2;
        p+=d*s;
        l+=(1.+sin(i+length(p.xy*.1)+vec3(3,1.5,1)))/s;
    }
    o.rgb=a(l*l/6e2);
}
