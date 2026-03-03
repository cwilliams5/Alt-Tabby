precision mediump float;

mat2 rotate2D(float r){
    return mat2(cos(r), sin(r), -sin(r), cos(r));
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    float i,e,f,s,g,k=.01;
    float o;
    o++;
    for(int i=0;i<100;i++)
    {
      s=2.;
      g+=min(f,max(.03,e))*.3;
      vec3 p=vec3((fragCoord.xy-iResolution.xy/s)/iResolution.y*g,g-s);
      p.yz*=rotate2D(-.8);
      p.y*=2.5;
      p.z+=iTime*1.3;
      e=p.y;
      f=p.y;
      for(;s<50.;)
      {
        s/=.66;
        p.xz*=rotate2D(s);
        e+=abs(dot(sin(p*s)/s,p-p+0.6));
        f+=abs(dot(sin(p.xz*s*.33+(iTime*0.5))/s,iResolution.xy/iResolution.xy));
      }

      if(f>k*k)
        o+=e*o*k;
      else
        o+=-exp(-f*f)*o*k;


    }
    fragColor = vec4(o*vec4(0.33,0.7,0.85,1.0));
}
