/*originals from gaz fractal 62*/
#define R(p,a,r)mix(a*dot(p,a),p,cos(r))+sin(r)*cross(p,a)
#define H(h)(cos((h)*6.3+vec3(25,20,21))*2.5+.5)
float happy_star(vec2 uv, float anim)
{
    uv = abs(uv);
    vec2 pos = min(uv.xy/uv.yx, anim);
    float p = (2.0 - pos.x - pos.y);
    return (2.0+p*(p*p-1.5)) / (uv.x+uv.y);
}
float hash( ivec3 p )    // this hash is not production ready, please
{                        // replace this by something better

    // 3D -> 1D
    int n = p.x*3 + p.y*113 + p.z*311;

    // 1D hash by Hugo Elias
	n = (n << 13) ^ n;
    n = n * (n * n * 15731 + 789221) + 1376312589;
    return float( n & ivec3(0x0fffffff))/float(0x0fffffff);
}

float noise( in vec3 x )
{
    ivec3 i = ivec3(floor(x));
    vec3 f = fract(x);
    f = f*f*(3.0-2.0*f);

    return mix(mix(mix( hash(i+ivec3(0,0,0)),
                        hash(i+ivec3(1,0,0)),f.x),
                   mix( hash(i+ivec3(0,1,0)),
                        hash(i+ivec3(1,1,0)),f.x),f.y),
               mix(mix( hash(i+ivec3(0,0,1)),
                        hash(i+ivec3(1,0,1)),f.x),
                   mix( hash(i+ivec3(0,1,1)),
                        hash(i+ivec3(1,1,1)),f.x),f.y),f.z);
}

void mainImage(out vec4 O, vec2 C)
{
    O=vec4(0);
      vec2 uv = ( C - .5*iResolution.xy ) / iResolution.y;
       float t2 = iTime * .1 + ((.25 + .05 * sin(iTime * .1))/(length(uv.xy) + .51)) * 2.2;
float si = sin(t2);
float co = cos(t2);
mat2 ma = mat2(co, si, -si, co);
    vec3 n1,q,r=iResolution,
    d=normalize(vec3((C*2.-r.xy)/r.y,1));
    for(float i=0.,a,s,e,g=0.;
        ++i<110.;
        O.xyz+=mix(vec3(1),H(g*.1),sin(.8))*1./e/8e3
    )
    {
     float c2 = noise(n1);
        n1=g*d+c2;

        n1.xy*=-ma;
         vec4 q=vec4(n1,sin(iTime*.15)*.5);
         q.xy*=ma;
        for(float j=0.;j++<4.;){
           for(float k=0.;k++<3.;){

           n1.x=cos(q.w*i+j);
            n1.y*=cos(q.x*i+j*q.z);

        }
        }

        a=20.;
        n1=mod(n1-a,a*2.)-a;
        s=3.+c2;


        for(int i=0;i++<8;){
            n1=.3-abs(n1);

            n1.x<n1.z?n1=n1.zyx:n1;
            n1.z<n1.y?n1=n1.xzy:n1;
            n1.y<n1.x?n1=n1.zyx:n1;



            q=abs(q);


            q=q.x<q.y?q.zwxy:q.zwyx;
            q=q.z<q.y?q.xyzw:q.ywxz;





            s*=e=1.4+sin(iTime*.234)*.1;
            n1=abs(n1)*e-
                vec3(
                    q.w+cos(iTime*.3+.5*cos(iTime*.3))*3.,
                    120.,
                    8.+cos(iTime*.5)*5.
                 );
         }

         g+=e=length(n1.xy)/s;

    }



      uv *= 2.0 * ( cos(iTime * 2.0) -2.5); // scale
    float anim = sin(iTime * 12.0) * 0.1 + 1.0;  // anim between 0.9 - 1.1
    O+= vec4(happy_star(uv, anim) * vec3(0.05,1.2,0.15)*0.1, 1.0);
}
