#define SHOW_SEGMENTS 1

// segment.x is distance to closest point
// segment.y is barycentric coefficient for closest point
// segment.z is length of closest point on curve, on the curve, starting from A
// segment.a is approximate length of curve
vec4 segment( vec2 p, vec2 a, vec2 b )
{
  a -= p;
  b -= p;
  vec3 k = vec3( dot(a,a) , dot(b,b) , dot(a,b) );
  float t = (k.x - k.z)/( k.x + k.y - 2.*k.z );
  float len = length(b-a);

  if( t < 0. ){
      return vec4( sqrt(k.x) , 0. , 0. , len );
  } else if( t > 1. ){
      return vec4( sqrt(k.y) , 1. , len , len );
  } else {
  	return vec4( length(a*(1.-t) + b*t) , t , t*len , len );
  }
}

// https://www.shadertoy.com/view/4djSRW
#define ITERATIONS 4


// *** Change these to suit your range of random numbers..

// *** Use this for integer stepped ranges, ie Value-Noise/Perlin noise functions.
#define HASHSCALE1 .1031
#define HASHSCALE3 vec3(.1031, .1030, .0973)
#define HASHSCALE4 vec4(1031, .1030, .0973, .1099)
//----------------------------------------------------------------------------------------
///  3 out, 2 in...
vec3 hash32(vec2 p)
{
	vec3 p3 = fract(vec3(p.xyx) * HASHSCALE3);
    p3 += dot(p3, p3.yxz+19.19);
    return fract((p3.xxy+p3.yzz)*p3.zyx);
}

vec3 hash3point(vec2 p)
{
    //vec3 col = hash32(p);
    vec3 col =
            hash32(p*1.25672+vec2(.2,.8))
          * hash32(vec2(p.y,p.x)/3.42464-vec2(.5,.0))
          - hash32(vec2(3.0+p.y,1.2))
    ;

    return pow(
        (abs(col)+max(col,0.0))/2.0
        , vec3(.6,.5,.4)
    );
}

float smoothFunction(float k)
{
    return 1.0 / ( 1.0 + k*k );
}

vec3 smoothFunction(vec3 k)
{
    return 1.0 / ( 1.0 + k*k );
}


float coeffDistPoint(vec2 uv,vec2 colPoint,float scale)
{
    //float dist = length(uv - colPoint) * scale;
    //dist = pow(dist,0.25);
    //dist = 1.0 - smoothstep(0.0,1.0,dist);

    vec2 uv_ = (uv - colPoint)*scale*24.0;
    float dist = dot(uv_,uv_);
    return  1.0 / ( 1.0 + dist );
}


vec3 mixColorLine(vec2 uv,vec3 currentCol,vec3 colLine,vec2 lineA,vec2 lineB,float scale)
{
    return mix(
        currentCol ,
        colLine ,
        1.0 - smoothstep(0.0,1.0,(sqrt( segment(uv,lineA,lineB).x * scale )))
    );
}

// pointA and pointB are on the same side of the half plane delimited by line (lineA,lineB)
bool pointsOnSameSideOfLine(vec2 pointA,vec2 pointB,vec2 lineA, vec2 lineB)
{
    vec2 n = lineB - lineA;
    n = vec2(n.y,-n.x);
    return  dot(pointA-lineA,n)
          * dot(pointB-lineA,n)
    > 0.0;
}


float viewportMagnify = 1.0;
vec2 screenToViewport(vec2 uv)
{
    return (uv - iResolution.xy/2.0 ) / min(iResolution.x,iResolution.y) * viewportMagnify;
}

vec2 viewportToScreen(vec2 uv,vec2 base)
{
    return (uv - base/4.0) / viewportMagnify * min(iResolution.x,iResolution.y) +  iResolution.xy/2.0;
    //return (uv - iResolution.xy/2.0 ) / min(iResolution.x,iResolution.y) * viewportMagnify;
}

float det22(vec2 a,vec2 b)
{
    return a.x*b.y - a.y*b.x;
}

struct Pinwheel
{
    vec2 A; // Right angle, divided into 1 acute and 1 obtuse
    vec2 B; // Acute angle, stays acute
    vec2 C; // Obtuse angle, stays obtuse

    vec2 D; // on GA
    vec2 E; // on AB
    vec2 F; // on BC, close to B
    vec2 G; // on BC, close to C
};

vec3 barycentricCoordinate(vec2 P,Pinwheel T)
{
    vec2 PA = P - T.A;
    vec2 PB = P - T.B;
    vec2 PC = P - T.C;

    vec3 r = vec3(
        det22(PB,PC),
        det22(PC,PA),
        det22(PA,PB)
    );

    return r / (r.x + r.y + r.z);
}


#define EQUERRE_COPY(T,Q) \
    T.A = Q.A; \
    T.B = Q.B; \
    T.C = Q.C;

#define EQUERRE_COMPUTE_DEFG(T) \
	T.E = (T.A + T.B)/2.0; \
	T.F = (3.0 * T.B + 2.0 * T.C)/5.0; \
	T.G = (T.B + 4.0 * T.C)/5.0; \
	T.D = (T.G + T.A)/2.0;

#define EQUERRE_GET1(T,Q) \
	T.A = Q.F; \
    T.B = Q.B; \
    T.C = Q.E;

#define EQUERRE_GET2(T,Q) \
	T.A = Q.F; \
    T.B = Q.G; \
    T.C = Q.E;

#define EQUERRE_GET3(T,Q) \
	T.A = Q.D; \
    T.B = Q.E; \
    T.C = Q.G;

#define EQUERRE_GET4(T,Q) \
	T.A = Q.D; \
    T.B = Q.E; \
    T.C = Q.A;

#define EQUERRE_GET5(T,Q) \
	T.A = Q.G; \
    T.B = Q.A; \
    T.C = Q.C;

#define EQUERRE_COND_12_345(X,T) \
	pointsOnSameSideOfLine(uv,T.F,T.E,T.G)

#define EQUERRE_COND_1_2(X,T) \
	pointsOnSameSideOfLine(uv,T.B,T.E,T.F)

#define EQUERRE_COND_34_5(X,T) \
	pointsOnSameSideOfLine(uv,T.E,T.A,T.G)

#define EQUERRE_COND_3_4(X,T) \
	pointsOnSameSideOfLine(uv,T.G,T.E,T.D)

#define EQUERRE_CENTER(T) ((T.A+T.B+T.C)/3.0)

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    fragColor = vec4(1.0);

    int nbIterations = iMouse.z > .5 ? 6 : 5;

    vec2 base = vec2(2.0,1.0);


	vec2 uv = screenToViewport(fragCoord.xy );

    viewportMagnify = 1./3.2;
    uv *= viewportMagnify;

    uv *= mat2(cos(iTime/48.+vec4(0.,1.6,-1.6,0.)));

    uv += base/3.2;

    // Base Triangle
    Pinwheel Tri;
    Pinwheel Tri_TMP;
    Tri.A = Tri.B = Tri.C = vec2(0.0);
    Tri.B.x += base.x;
    Tri.C.y += base.y;
    int PinwheelID = 0;

    for(int i = 0 ; i < nbIterations ; i++)
    {
        PinwheelID *= 5;
        EQUERRE_COMPUTE_DEFG(Tri);

        if( EQUERRE_COND_12_345(uv,Tri) )
        {
            if( EQUERRE_COND_1_2(uv,Tri) )
            {
            	EQUERRE_GET1(Tri_TMP,Tri);
            }
            else
            {
            	EQUERRE_GET2(Tri_TMP,Tri);
                PinwheelID += 1;
            }
        }
        else if( EQUERRE_COND_34_5(uv,Tri) )
        {
            if( EQUERRE_COND_3_4(uv,Tri) )
            {
            	EQUERRE_GET3(Tri_TMP,Tri);
                PinwheelID += 2;
            }
            else
            {
            	EQUERRE_GET4(Tri_TMP,Tri);
                PinwheelID += 3;
            }
        }
        else
        {
            EQUERRE_GET5(Tri_TMP,Tri);
            PinwheelID += 4;
        }

        EQUERRE_COPY(Tri,Tri_TMP);
    }

    //fragColor.rgb = hash3point(EQUERRE_CENTER(Tri));
    vec3 v = cos(
             iTime/vec3(63.,54.,69.)/float(nbIterations)/1.2
              + vec3(.0,.95,1.22)
             )
             * vec3(36.,34.,31.)
             + vec3(25.,19.,42.);
    vec3 s = vec3( sin(iTime/3.0)*.5+.5 ,iMouse.xy/iResolution.xy);
    fragColor.rgb = mod(vec3(PinwheelID),v)/(v-1.);
    fragColor.rgb = mod(fragColor.rgb+s,1.);
    // interesting variation
    // but needs tuning in color
    //fragColor = sqrt( cos(fragColor*3.14*vec4(1.,2.,3.,1.))*.5+.5 );

    float scale = float(nbIterations);
    scale = pow(2.0,scale)/viewportMagnify/scale*5.5;

    vec3 EquerreColor = vec3(0.);

    #if SHOW_SEGMENTS==1
        #define OPERATION1(x,y) fragColor.rgb = mixColorLine(uv,fragColor.rgb,EquerreColor,x,y,scale);
    	OPERATION1(Tri.A,Tri.B);
    	OPERATION1(Tri.B,Tri.C);
    	OPERATION1(Tri.C,Tri.A);
    #endif



    fragColor.rgb = tanh(fragColor.rgb*6.);
}
