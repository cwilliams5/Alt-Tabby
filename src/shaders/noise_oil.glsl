#define PI 3.141592
#define TWOPI 6.283184

#define R2D 180.0/PI*
#define D2R PI/180.0*

mat2 rotMat(in float r){float c = cos(r);float s = sin(r);return mat2(c,-s,s,c);}

//fract -> -0.5 -> ABS  : coordinate absolute Looping
float abs1d(in float x){return abs(fract(x)-0.5);}
vec2 abs2d(in vec2 v){return abs(fract(v)-0.5);}

#define OC 15.0
vec3 Oilnoise(in vec2 pos, in vec3 RGB)
{
    vec2 q = vec2(0.0);
    float result = 0.0;

    float s = 2.2;
    float gain = 0.44;
    vec2 aPos = abs2d(pos)*0.5;//add pos

    for(float i = 0.0; i < OC; i++)
    {
        pos *= rotMat(D2R 30.);
        float time = (sin(iTime)*0.5+0.5)*0.2+iTime*0.8;
        q =  pos * s + time;
        q =  pos * s + aPos + time;
        q = vec2(cos(q));

        result += abs1d(dot(q, vec2(0.3))) * gain;

        s *= 1.07;
        aPos += cos(q);
        aPos*= rotMat(D2R 5.0);
        aPos*= 1.2;
    }

    result = pow(result,4.0);
    return clamp( RGB / result, vec3(0.0), vec3(1.0));
}


void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    vec3 col = vec3(0.0,0.0,0.0);
    vec2 st = (fragCoord/iResolution.xy);
            st.x = ((st.x - 0.5) *(iResolution.x / iResolution.y)) + 0.5;
    float stMask = step(0.0, st.x * (1.0-st.x));


    //st-=.5; //st move centor. Oil noise sampling base to 0.0 coordinate
    st*=5.;

    col =Oilnoise(st,vec3(0.30, 0.7, 1.200));
    //col *= stMask;

    fragColor = vec4(col,1.0);
}
