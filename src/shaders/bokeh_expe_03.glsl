//tutorial https://youtu.be/52TMliAWocY

#define S(x, y, t) smoothstep(x, y, t)


struct ray {
    vec3 o,d;
};

ray GetRay(vec2 uv, vec3 camPos, vec3 lookat, float zoom){
    ray a;
    a.o = camPos;

    vec3 f = normalize(lookat-camPos);
    vec3 r = cross(vec3(0,1,0),f);
    vec3 u = cross(f,r);
    vec3 c = a.o + f*zoom;
    vec3 i = c+uv.x*r+uv.y *u;
    a.d=normalize(i-a.o);

    return a;
}



vec4 N14(float t){
    return fract(sin(t*vec4(123.,1024.,3456.,9575.))*vec4(2348.,125.,2518,6578.));
}

float N(float t){
    return fract(sin(t*1258.)*6527.);
}


vec3 ClosetPoint(ray r, vec3 p){
    return r.o+max(0.,dot(p-r.o,r.d))*r.d;

}

float DistRay(ray r, vec3 p){
    return length(p-ClosetPoint(r,p));
}

float Bokeh (ray r, vec3 p, float size, float blur){
    size*=length(p);
    float d = DistRay(r,p);
    float c = S(size, size*(1.-blur),d);
    c*=mix(.6,1.,S(size*.8,size,d));
    return c;

}

vec3 Streetlights(ray r, float t){
    float side = step(r.d.x,0.);

    r.d.x=abs(r.d.x)-.08;

    float s = 1./10.;
    float m = 0.;

    for(float i=0.; i < 1.; i+=s){
    float ti = fract(t+i+side*s*.5);
    vec3 p = vec3(2.,2.,100.-ti*100.);
    m+= Bokeh(r,p,.1,.1)*ti*ti*ti*ti;
    }
    return  vec3(1.,.7,.3)*m;

}


vec3 Envlights(ray r, float t){
    float side = step(r.d.x,0.);

    r.d.x=abs(r.d.x)-.08;

    float s = 1./10.;
    //float m = 0.;
    vec3 c = vec3(0.);

    for(float i=0.; i < 1.; i+=s){
    float ti = fract(t+i+side*s*.5);

    vec4 n = N14(i+side*100.);//make it asymetrical

    float fade = ti*ti*ti*ti;

    float occlusion = sin(ti*6.28*10.*n.x)*.5+.5;//times 2 pi

    fade = occlusion;

    float x = mix(2.5,10.,n.x);
    float y = mix(.1,1.5,n.y);


    vec3 p = vec3(x,y,50.-ti*50.);
    vec3 col = n.wzy;// random color
    c+= Bokeh(r,p,.1,.1)*fade *col*.2;
    }
    return  c;

}

vec3 Headlights(ray r, float t){
    t*=.5;

   float w1 = .35;// distance between headlight
   float w2 = w1*1.2;

    float s = 1./30.;// divider is the number of cars
    float m = 0.;

    for(float i=0.; i < 1.; i+=s){

        float n = N(i);// randomize the headlight using noise
        if(n>.1) continue;// jump back to for loop while not executing below

        float ti = fract(t+i);
        float z = 100.-ti*100.;
        float fade =ti*ti*ti*ti;

        float focus = S(.8,1.,ti);
        float size = mix(.05,.03,focus);

        m+= Bokeh(r,vec3(-1.-w1,.15,z),size,.1)*fade;
        m+= Bokeh(r,vec3(-1.+
        w1,.15,z),size,.1)*fade;

        m+= Bokeh(r,vec3(-1.-w2,.15,z),size,.1)*fade;
        m+= Bokeh(r,vec3(-1.+
        w2,.15,z),size,.1)*fade;


        float ref = 0.; //reflection
        ref+= Bokeh(r,vec3(-1.-w2,-.15,z),size*3.,1.)*fade;
        ref+= Bokeh(r,vec3(-1.+
        w2,-.15,z),size*3.,1.)*fade;

        m+=ref*focus;//only show reflection when in focus
    }

    return vec3(.9,.9,1.)*m;//blue and green

}

vec3 Taillights(ray r, float t){

    t *=.8;

    float w1 = .25;// distance between headlight
    float w2 = w1*1.2;

    float s = 1./15.;// divider is the number of cars
    float m = 0.;

    for(float i=0.; i < 1.; i+=s){

        float n = N(i);// 0 1 randomize the headlight using noise

        if(n>.1) continue;// jump back to for loop while not executing below

        // n = 0 0.5
        float lane = step(.5,n);// 0 1

        float ti = fract(t+i);
        float z = 100.-ti*100.;
        float fade =ti*ti*ti*ti*ti;

        float focus = S(.9,1.,ti);
        float size = mix(.05,.03,focus);

        float laneShift = S(.99,.96,ti);
        float x = 1.5 -lane*laneShift;

        float blink = step(0.,sin(t*10000.))*7.*lane*step(.96,ti);

        m+= Bokeh(r,vec3(x-w1,.15,z),size,.1)*fade;
        m+= Bokeh(r,vec3(x+
        w1,.15,z),size,.1)*fade;

        m+= Bokeh(r,vec3(x-w2,.15,z),size,.1)*fade;
        m+= Bokeh(r,vec3(x+
        w2,.15,z),size,.1)*fade*(1.+blink);


        float ref = 0.; //reflection
        ref+= Bokeh(r,vec3(x-w2,-.15,z),size*3.,1.)*fade;
        ref+= Bokeh(r,vec3(x+
        w2,-.15,z),size*3.,1.)*fade*(1.+blink*.1);

        m += ref*focus;//only show reflection when in focus
    }

    return vec3(1.,.1,.03)*m;//red

}



vec2 Rain(vec2 uv, float t){
    t*=40.;

    //uv*=3.;
    vec2 a = vec2(3.,1.);
    vec2 st = uv*a;
    st.y+=t*.2;
    vec2 id = floor(st);

    float n = fract(sin(id.x*716.34)*768.34);//creating a quick random function

    uv.y+=n;
    st.y+=n;

    id = floor(st);
    st = fract(st)-.5;

    t += fract(sin(id.x*76.34+id.y*1453.7)*768.35)*6.283;//create phase difference

    float y = -sin(t+sin(t+sin(t)*.5))*.43;//making sawtooth wave so goes up fast and goes down slower
    vec2 p1 = vec2(0.,y);

    vec2 o1 = (st-p1)/a;
    float d = length(o1);

    float m1 = S(.07,.0,d);

    //leave a trail of waterdrops

    vec2 o2 = fract(uv*a.x*vec2(1.,2.)-.5)/vec2(1.,2.);
    d = length(o2);
    float m2 = S(.3*(.5-st.y),.0,d)*S(-.1,.1,st.y-p1.y);

   // if(st.x>.46 || st.y>.49) m1=1.;// drawing grid



    return vec2(m1*o1*50.+m2*o2*10.);//m2



}
void mainImage( out vec4 fragColor, in vec2 fragCoord ){
    // Normalized pixel coordinates (from 0 to 1)
    vec2 uv = fragCoord.xy/iResolution.xy;
    uv-=.5;
    uv.x*=iResolution.x/iResolution.y;

    vec2 m = iMouse.xy/iResolution.xy;
    float t = iTime*.05+m.x;

    vec3 camPos = vec3(.5,.18,0.);
    vec3 lookat = vec3(.5,.22,1.);

    vec2 rainDistort = Rain(uv*5.,t)*.5;

   rainDistort += Rain(uv*7.,t)*.5;


   //making water effect
   uv.x+=sin(uv.y*70.)*.005;
   uv.y+=sin(uv.x*170.)*.003;

   ray r = GetRay(uv-rainDistort*.5,camPos,lookat,2.);


    vec3 col = Streetlights(r,t);
    col += Headlights(r,t);
    col += Taillights(r,t);
    col += Envlights(r,t);

    col+=(r.d.y+.25)*vec3(.2,.1,.5);

   // col=vec3(rainDistort,0.);


fragColor = vec4(col,1.);
}
