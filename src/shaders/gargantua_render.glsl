//This is simple render of black hole with gravitational lensing
//Rendering participating media is one of the most complecated part of production rendering
//and rendering heterogenious particifating media illuminated from heterogenious volumetric
//light sorce within gravitational lensing is practically imposible in significant frame rates.
//So I decided to implement only lensing part. lighting isn't calculated.


//random number and cloud generation is taken from iq :)
float seed;	//seed initialized in main
float rnd() { return fract(sin(seed++)*43758.5453123); }
//***********************************

//used macros and constants
#define PI 					3.1415926
#define TWO_PI 				6.2831852
#define FOUR_PI 			12.566370
#define HALF_PI 			1.5707963
#define INV_PI 				0.3183099
#define INV_TWO_PI 			0.1591549
#define INV_FOUR_PI 		0.0795775
#define EPSILON 			0.00001
#define IN_RANGE(x,a,b)		(((x) > (a)) && ((x) < (b)))
#define EQUAL_FLT(a,b,eps)	(((a)>((b)-(eps))) && ((a)<((b)+(eps))))
#define IS_ZERO(a) 			EQUAL_FLT(a,0.0,EPSILON)

//Increase SPP to remove noise :)
#define SPP 4
#define GRAVITATIONAL_LENSING

struct Ray {
    vec3 origin;
    vec3 dir;
};

struct Camera {
    mat3 rotate;
	vec3 pos;
    vec3 target;
    float fovV;
};

struct BlackHole {
    vec3 position_;
    float radius_;
    float ring_radius_inner_;
    float ring_radius_outer_;
    float ring_thickness_;
    float mass_;
};

BlackHole gargantua;
Camera camera;

void initScene() {
    gargantua.position_ = vec3(0.0, 0.0, -8.0 );
    gargantua.radius_ = 0.1;
    gargantua.ring_radius_inner_ = gargantua.radius_ + 0.8;
    gargantua.ring_radius_outer_ = 6.0;
    gargantua.ring_thickness_ = 0.15;
    gargantua.mass_ = 1000.0;
}

void initCamera( in vec3 pos, in vec3 target, in vec3 upDir, in float fovV ) {
	vec3 back = normalize( pos-target );
	vec3 right = normalize( cross( upDir, back ) );
	vec3 up = cross( back, right );
    camera.rotate[0] = right;
    camera.rotate[1] = up;
    camera.rotate[2] = back;
    camera.fovV = fovV;
    camera.pos = pos;
}

vec3 sphericalToCartesian(	in float rho,
                          	in float phi,
                          	in float theta ) {
    float sinTheta = sin(theta);
    return vec3( sinTheta*cos(phi), sinTheta*sin(phi), cos(theta) )*rho;
}

void cartesianToSpherical( 	in vec3 xyz,
                         	out float rho,
                          	out float phi,
                          	out float theta ) {
    rho = sqrt((xyz.x * xyz.x) + (xyz.y * xyz.y) + (xyz.z * xyz.z));
    phi = asin(xyz.y / rho);
	theta = atan( xyz.z, xyz.x );
}

Ray genRay( in vec2 pixel )
{
    Ray ray;

	vec2 iPlaneSize=2.*tan(0.5*camera.fovV)*vec2(iResolution.x/iResolution.y,1.);
	vec2 ixy=(pixel/iResolution.xy - 0.5)*iPlaneSize;

    ray.origin = camera.pos;
    ray.dir = camera.rotate*normalize(vec3(ixy.x,ixy.y,-1.0));

	return ray;
}

float noise( in vec3 x ) {
    vec3 p = floor(x);
    vec3 f = fract(x);
	f = f*f*(3.0-2.0*f);
	vec2 uv = ( p.xy + vec2(37.0,17.0)*p.z ) + f.xy;
	vec2 rg = textureLod( iChannel0, (uv+ 0.5)/256.0, 0.0 ).yx;
	return -1.0+2.0*mix( rg.x, rg.y, f.z );
}

float map5( in vec3 p ) {
	vec3 q = p;
	float f;
    f  = 0.50000*noise( q ); q = q*2.02;
    f += 0.25000*noise( q ); q = q*2.03;
    f += 0.12500*noise( q ); q = q*2.01;
    f += 0.06250*noise( q ); q = q*2.02;
    f += 0.03125*noise( q );
	return clamp( 1.5 - p.y - 2.0 + 1.75*f, 0.0, 1.0 );
}

//***********************************************************************
// Stars from: nimitz
// https://www.shadertoy.com/view/ltfGDs
//***********************************************************************
float tri(in float x){return abs(fract(x)-.5);}

vec3 hash33(vec3 p){
	p  = fract(p * vec3(5.3983, 5.4427, 6.9371));
    p += dot(p.yzx, p.xyz  + vec3(21.5351, 14.3137, 15.3219));
	return fract(vec3(p.x * p.z * 95.4337, p.x * p.y * 97.597, p.y * p.z * 93.8365));
}

//smooth and cheap 3d starfield
vec3 stars(in vec3 p)
{
    float fov = radians(50.0);
    vec3 c = vec3(0.);
    float res = iResolution.x*.85*fov;

    //Triangular deformation (used to break sphere intersection pattterns)
    p.x += (tri(p.z*50.)+tri(p.y*50.))*0.006;
    p.y += (tri(p.z*50.)+tri(p.x*50.))*0.006;
    p.z += (tri(p.x*50.)+tri(p.y*50.))*0.006;

	for (float i=0.;i<3.;i++)
    {
        vec3 q = fract(p*(.15*res))-0.5;
        vec3 id = floor(p*(.15*res));
        float rn = hash33(id).z;
        float c2 = 1.-smoothstep(-0.2,.4,length(q));
        c2 *= step(rn,0.005+i*0.014);
        c += c2*(mix(vec3(1.0,0.75,0.5),vec3(0.85,0.9,1.),rn*30.)*0.5 + 0.5);
        p *= 1.15;
    }
    return c*c*1.5;
}
//*****************************************************************************

vec3 getBgColor( vec3 dir ) {
    float rho, phi, theta;
    cartesianToSpherical( dir, rho, phi, theta );

    vec2 uv = vec2( phi/PI, theta/TWO_PI );
    vec3 c0 = texture( iChannel1, uv).xyz*0.3;
    vec3 c1 = stars(dir);
    return c0.bgr*0.4 + c1*2.0;
}

void getCloudColorAndDencity(vec3 p, float time, out vec4 color, out float dencity ) {
    float d2 = dot(p,p);

    if( sqrt(d2) < gargantua.radius_ ) {
        dencity = 0.0;
    } else {
        float rho, phi, theta;
        cartesianToSpherical( p, rho, phi, theta );

        //normalize rho
        rho = ( rho - gargantua.ring_radius_inner_)/(gargantua.ring_radius_outer_ - gargantua.ring_radius_inner_);

        if( !IN_RANGE( p.y, -gargantua.ring_thickness_, gargantua.ring_thickness_ ) ||
            !IN_RANGE( rho, 0.0, 1.0 ) ) {
            dencity = 0.0;
        } else {
            float cloudX = sqrt( rho );
            float cloudY = ((p.y - gargantua.position_.y) + gargantua.ring_thickness_ ) / (2.0*gargantua.ring_thickness_);
            float cloudZ = (theta/TWO_PI);

            float blending = 1.0;

            blending *= mix(rho*5.0, 1.0 - (rho-0.2)/(0.8*rho), rho>0.2);
            blending *= mix(cloudY*2.0, 1.0 -(cloudY-0.5)*2.0, cloudY > 0.5);

            vec3 moving = vec3( time*0.5, 0.0, time*rho*0.1 );

            vec3 localCoord = vec3( cloudX*(rho*rho), -0.02*cloudY, cloudZ );

            dencity = blending*map5( (localCoord + moving)*100.0 );
            color = 5.0*mix( vec4( 1.0, 0.9, 0.4, rho*dencity ), vec4( 1.0, 0.3, 0.1, rho*dencity ), rho );
        }
    }
}

vec4 Radiance( in Ray ray )
{
	vec4 sum = vec4(0.0);

    float marchingStep = mix( 0.27, 0.3, rnd() );
    float marchingStart = 2.5;

    Ray currentRay = Ray ( ray.origin + ray.dir*marchingStart, ray.dir );

    float transmittance = 1.0;

    for(int i=0; i<64 && transmittance > 1e-3; i++) {
        vec3 p = currentRay.origin - gargantua.position_;

        float dencity;
        vec4 ringColor;
        getCloudColorAndDencity(p, iTime*0.1, ringColor, dencity);

        ringColor *= marchingStep;

        float tau = dencity * (1.0 - ringColor.w) * marchingStep;
        transmittance *= exp(-tau);

        sum += transmittance * dencity*ringColor;

#ifdef GRAVITATIONAL_LENSING
        float G_M1_M2 = 0.50;
        float d2 = dot(p,p);
        vec3 gravityVec = normalize(-p)*( G_M1_M2/d2 );

        currentRay.dir = normalize( currentRay.dir + marchingStep * gravityVec );
#endif
        currentRay.origin = currentRay.origin + currentRay.dir*(marchingStep);
    }

    vec3 bgColor = getBgColor( currentRay.dir );
    sum = vec4( bgColor*transmittance + sum.xyz, 1.0 );

    return clamp( sum, 0.0, 1.0 );
}

void mainImage( out vec4 fragColor, in vec2 fragCoord ) {
    seed = /*iTime +*/ iResolution.y * fragCoord.x / iResolution.x + fragCoord.y / iResolution.y;

    initScene();

    vec2 screen_uv = (iMouse.x!=0.0 && iMouse.y!=0.0)?iMouse.xy/iResolution.xy:vec2( 0.8, 0.4 );

    float mouseSensitivity = 0.4;
    vec3 cameraDir = sphericalToCartesian( 1.0, -((HALF_PI - (screen_uv.y)*PI)*mouseSensitivity), (-screen_uv.x*TWO_PI)*mouseSensitivity );

    initCamera( gargantua.position_ + cameraDir*8.0, gargantua.position_, vec3(0.2, 1.0, 0.0), radians(50.0) );

    vec4 color = vec4( 0.0, 0.0, 0.0, 1.0 );
    for( int i=0; i<SPP; i++ ){
    	vec2 screenCoord = fragCoord.xy + vec2( rnd(), rnd() );
    	Ray ray = genRay( screenCoord );

        color += Radiance( ray );
    }

    fragColor = (1.0/float(SPP))*color;
}