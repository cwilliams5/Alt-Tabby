// LineSynapse

#define iterations 13
#define formuparam 0.53

#define volsteps 20
#define stepsize 0.1

#define zoom   0.800
#define tile   0.850
#define speed  0.000

#define brightness 0.0015
#define darkmatter 0.300
#define distfading 0.730
#define saturation 0.850
#define S(a,b,t) smoothstep(a,b,t)

float DistLine(vec2 p, vec2 a, vec2 b){
    vec2 pa = p-a;
    vec2 ba = b-a;
    float t = clamp(dot(pa,ba)/dot(ba,ba),0., 1.);
    return length(pa-ba*t);


}

float N21(vec2 p){
    p=fract(p*vec2(233.34,851.73));
    p+=dot(p,p+23.45);
    return fract(p.x*p.y);

}

vec2 N22(vec2 p){
    float n=N21(p);
    return vec2(n,N21(p+n));

}

vec2 GetPos(vec2 id,vec2 offs){


    vec2 n = N22(id+offs)*iTime;

    return offs+cos(n)*sin(n)*.5;

}
float Line(vec2 p,vec2 a, vec2 b){
    float d = DistLine(p,a,b);
    float m = S(.06,.01,d);
    float d2 = length(a-b);
    m *= S(2.2, .8, d2)+S(.05,.03,abs(d2-.75));
    return m;

}
float Layer(vec2 uv){
    float m =0.;
    vec2 gv = fract(uv)-.5;
    vec2 id = floor(uv);

    vec2 p[9];
    int i=0;
    for(float y=-1.;y<=1.;y++){
        for(float x=-1.;x<=1.;x++){
            p[i++] = GetPos(id,vec2(x,y));

        }

    }
    float t = iTime*10.0;
    for(int i=0;i<9;i++){
        m+= Line(gv,p[4],p[i]);
        vec2 j = (p[i] - gv)*15.;
        float sparkle = 1./dot(j,j);

        m += sparkle*(sin(t+fract(p[i].x)*10.)*.5+.5);

    }
    m+= Line(gv,p[1],p[3]);
    m+= Line(gv,p[1],p[5]);
    m+= Line(gv,p[7],p[3]);
    m+= Line(gv,p[7],p[5]);
    return m;
}

void mainVR( out vec4 fragColor, in vec2 fragCoord, in vec3 ro, in vec3 rd )
{
    //get coords and direction
    vec3 dir=rd;
    vec3 from=ro;

    //volumetric rendering
    float s=0.1,fade=1.;
    vec3 v=vec3(0.);
    for (int r=0; r<volsteps; r++) {
        vec3 p=from+s*dir*.5;
        p = abs(vec3(tile)-mod(p,vec3(tile*2.))); // tiling fold
        float pa,a=pa=0.;
        for (int i=0; i<iterations; i++) {
            p=abs(p)/dot(p,p)-formuparam;
            p.xy*=mat2(cos(iTime*0.05),sin(iTime*0.05),-sin(iTime*0.05),cos(iTime*0.05) );// the magic formula
            a+=abs(length(p)-pa); // absolute sum of average change
            pa=length(p);
        }
        float dm=max(0.,darkmatter-a*a*.001); //dark matter
        a*=a*a; // add contrast
        if (r>6) fade*=1.3-dm; // dark matter, don't render near
        //v+=vec3(dm,dm*.5,0.);
        v+=fade;
        v+=vec3(s,s*s,s*s*s*s)*a*brightness*fade; // coloring based on distance
        fade*=distfading; // distance fading
        s+=stepsize;
    }
    v=mix(vec3(length(v)),v,saturation); //color adjust
    fragColor = vec4(v*.03,1.);
}
#define REFLECTION_NUMBER 40

mat3 rotation(float angle)
{
    float c = cos(angle);
    float s = sin(angle);
    return mat3( c, -s, 0.,  s, c, 0.,  0., 0., 1.);
}
void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    //get coords and direction
    vec2 uv=fragCoord.xy/iResolution.xy-.5;
    uv.y*=iResolution.y/iResolution.x;
    vec3 dir=vec3(uv*zoom,1.);
    float time=iTime*speed+.25;
vec2 mo = length(iMouse.xy - vec2(0.0)) < 1.0 ? vec2(0.0) : (iMouse.xy - iResolution.xy*.5)/iResolution.y*3.;


    vec3 huv = vec3(uv, 0.);
    huv *= rotation(iTime*.2);

    vec3 axisOrigin = vec3(0., 0., 1.);
    vec3 axisDirection = vec3(normalize(vec2(1., 1.)), 0.);

    for(int i = 0; i < REFLECTION_NUMBER; i++)
    {
        float offset = (3.1415 * 2. / float(REFLECTION_NUMBER) ) * float(i);
        float axisRotation = offset;
        vec3 tuv = (huv - axisOrigin) * rotation(-axisRotation);
        if(tuv.y < 0.)
        {
            vec3 invuv = tuv;
            invuv.y = -invuv.y;
            invuv = (invuv * rotation(axisRotation)) + axisOrigin;
            huv = invuv;
        }
    }

    vec3 col2 = vec3(texture(iChannel0, huv.xy - vec2(iTime *.2, 0.) ));

    vec3 sky = vec3(texture(iChannel1, huv.xy)).xyz;

    col2 = mix(sky, col2, abs(sin(iTime/2.0)));

    float gradient = uv.y;
    float m = 0.;
    float t = iTime*.1;
    float s = sin(t);
    float c = cos(t);
    mat2 rot = mat2(c,-s,s,c);
  ;

    for( float i=0.;i<=1.;i+=1./7.){
        float z=fract(i*i+t);
        float size = mix(59.,.5,z);
        float fade = S(0.,.2,z)*S(1.,.0,z);
        m+=Layer(uv*size+i*200.)*fade;
    }
    vec3 base = sin(t*5.*vec3(.345,.456,.657))*.5+.6;
    vec3 col = m*base;
    col -=gradient*base;
    vec3 from=vec3(1.,.5,0.5);

    mainVR(fragColor, fragCoord, from, dir);
    fragColor*=vec4(col,1.);
}
