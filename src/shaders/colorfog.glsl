//philip.bertani@gmail.com

float numOct  = 4. ;  //number of fbm octaves
float focus = 0.;
float focus2 = 0.;
#define pi  3.14159265

float random(vec2 p) {
    //a random modification of the one and only random() func
    return fract( sin( dot( p, vec2(12., 90.)))* 5e5 );
}

mat2 rot2(float an){float cc=cos(an),ss=sin(an); return mat2(cc,-ss,ss,cc);}

//this is the noise func everyone uses...
float noise(vec3 p) {
    vec2 i = floor(p.yz);
    vec2 f = fract(p.yz);
    float a = random(i + vec2(0.,0.));
    float b = random(i + vec2(1.,0.));
    float c = random(i + vec2(0.,1.));
    float d = random(i + vec2(1.,1.));
    vec2 u = f*f*(3.-2.*f);

    return mix( mix(a,b,u.x), mix(c,d,u.x), u.y);
}

float fbm3d(vec3 p) {
    float v = 0.;
    float a = .35;

    for (float i=0.; i<numOct; i++) {
        v += a * noise(p);
        a *= .25*(1.2+focus+focus2);
    }
    return v;
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{

    vec2 uv = (2.*fragCoord-iResolution.xy)/iResolution.y * 2.5;

    float aspectRatio = iResolution.x / iResolution.y;

    vec3 rd = normalize( vec3(uv, -1.2) );
    vec3 ro = vec3(0);

    float delta = iTime / 1.5 ;

    rd.yz *= rot2(-delta/2. );
    rd.xz *= rot2(delta*3.);
    vec3 p = ro + rd;

    float bass = 1.5 +  .5*max(0.,2.*sin(iTime*3.));

    vec2 nudge = vec2( aspectRatio*cos(iTime*1.5), sin(iTime*1.5));

    focus = length(uv + nudge);
    focus = 2./(1.+focus) * bass;

    focus2 = length(uv - nudge);
    focus2 = 4./(1.+focus2*focus2) / bass;

    vec3 q = vec3( fbm3d(p), fbm3d(p.yzx), fbm3d(p.zxy) ) ;

    float f = fbm3d(p + q);

    vec3 cc = q;
    cc *= 20.*f;

    cc.r += 5.*focus; cc.g+= 3.5*focus;
    cc.b += 7.*focus2; cc.r-= 3.5*focus2;
    cc /= 25.;

    fragColor = vec4( cc,1.0);

}
