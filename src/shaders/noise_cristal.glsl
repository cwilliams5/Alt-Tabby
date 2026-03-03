// From https://www.shadertoy.com/view/XX33zs

#define PI 3.141592
#define TWOPI 6.283184

#define R2D 180.0/PI*
#define D2R PI/180.0*


mat2 rotMat(in float r){float c = cos(r);float s = sin(r);return mat2(c,-s,s,c);}

//fract -> -0.5 -> ABS  : coordinate absolute Looping
float abs1d(in float x){return abs(fract(x)-0.5);}
vec2 abs2d(in vec2 v){return abs(fract(v)-0.5);}
float cos1d(float p){ return cos(p*TWOPI)*0.25+0.25;}
float sin1d(float p){ return sin(p*TWOPI)*0.25+0.25;}

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

        result += sin1d(dot(q, vec2(0.3))) * gain;

        s *= 1.07;
        aPos += cos(smoothstep(0.0,0.15,q));
        aPos*= rotMat(D2R 5.0);
        aPos*= 1.232;
    }

    result = pow(result,4.504);
    return clamp( RGB / abs1d(dot(q, vec2(-0.240,0.000)))*.5 / result, vec3(0.0), vec3(1.0));
}


void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    vec3 col = vec3(0.0,0.0,0.0);
    vec2 st = (fragCoord/iResolution.xy);
            st.x = ((st.x - 0.5) *(iResolution.x / iResolution.y)) + 0.5;
    float stMask = step(0.0, st.x * (1.0-st.x));


    //st-=.5; //st move centor. Oil noise sampling base to 0.0 coordinate
    st*=3.;

    vec3 rgb = vec3(0.30, .8, 1.200);


    //berelium, 2024-06-07 - anti-aliasing
    float AA = 1.0;
    vec2 pix = 1.0 / iResolution.xy;
    vec2 aaST = vec2(0.0);

    for(float i = 0.0; i < AA; i++)
    {
        for(float j = 0.0; j < AA; j++)
        {
            aaST = st + pix * vec2( (i+0.5)/AA, (j+0.5)/AA );
            col += Oilnoise(aaST, rgb);
        }

    }

    col /= AA * AA;

    //col =Oilnoise(st,rgb);
    //col *= stMask;

    fragColor = vec4(col,1.0);
}
