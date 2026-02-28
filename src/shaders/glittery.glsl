// Glittery
// Based on https://www.shadertoy.com/view/lslyRn
//          https://www.shadertoy.com/view/lscczl

#define iterations 17
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
p=abs(p)/dot(p,p)-formuparam; // the magic formula
a+=abs(length(p)-pa); // absolute sum of average change
pa=length(p);
}
float dm=max(0.,darkmatter-a*a*.001); //dark matter
a*=a*a; // add contrast
if (r>6) fade*=1.1; // dark matter, don't render near
//v+=vec3(dm,dm*.5,0.);
v+=fade;
v+=vec3(s,s*s,s*s*s*s)*a*brightness*fade; // coloring based on distance
fade*=distfading; // distance fading
s+=stepsize;
}
v=mix(vec3(length(v)),v,saturation); //color adjust
fragColor = vec4(v*.03,1.);
}
const float pi = 3.14159265359;
const float triangleScale = 0.816497161855865; // ratio of edge length and height
const vec3 orange = vec3(0.937, 0.435, 0.0);

float rand(vec2 co){
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

vec4 getTriangleCoords(vec2 uv) {
    uv.y /= triangleScale;
    uv.x -= uv.y / 2.0;
    vec2 center = floor(uv);
    vec2 local = fract(uv);

    center.x += center.y / 2.0;
    center.y *= triangleScale;

    if (local.x + local.y > 1.0) {
    local.x -= 1.0 - local.y;
        local.y = 1.0 - local.y;
        center.y += 0.586;
        center.x += 1.0;
    } else {
        center.y += 0.287;
    center.x += 0.5;
    }

    return vec4(center, local);
}

vec4 getLoader(vec4 triangle) {
    if (length(triangle.xy) > 1.6) {
        return vec4(0.0);
    }

    float angle = atan(triangle.x, triangle.y);
    float seed = rand(triangle.xy);
    float dst = min(triangle.z, min(triangle.w, 1.0 - triangle.z - triangle.w)) * 15.0;
    float glow = dst < pi ? pow(sin(dst), 1.5) : 0.0;

    return vec4(mix(orange, vec3(1.0), glow * 0.07), pow(0.5 + 0.5 * sin(angle - iTime * 6.0 + seed), 2.0));
}

float getBackground(vec4 triangle) {
    float dst = min(triangle.z, min(triangle.w, 1.0 - triangle.z - triangle.w)) - 0.05;

    if (triangle.y > 1.9 || triangle.y < -2.4 || dst < 0.0) {
        return 0.0;
    }

    float value = pow(0.5 + 0.5 * cos(-abs(triangle.x) * 0.4 + rand(triangle.xy) * 2.0 + iTime * 4.0), 2.0) * 0.08;
    return value * (dst > 0.05 ? 0.65 : 1.0);
}

vec3 getColor(vec2 uv) {
    uv *= 2.0 / iResolution.y;

    vec3 background = vec3(getBackground(getTriangleCoords(uv * 6.0 - vec2(0.5, 0.3))));
  vec4 loader = getLoader(getTriangleCoords(uv * 11.0));

    vec3 color = mix(background, loader.rgb, loader.a);
    return color;
}
#define S(a, b, t) smoothstep(a, b, t)

float distLine(vec2 p, vec2 a, vec2 b){
vec2 pa = p - a;
    vec2 ba = b - a;
    float t = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba*t);
}

float line(vec2 p, vec2 a, vec2 b){
float d = distLine(p, a, b);
    float m = S(0.03, 0.01, d);
    float d2 =  length(a - b);
    m *= S(1.2, 0.8, d2) * 0.5 + S(0.05, 0.03, abs(d2 - 0.75));
    return m;
}

float distTriangle(in vec2 p, in vec2 p0, in vec2 p1, in vec2 p2 )
{
vec2 e0 = p1 - p0;
vec2 e1 = p2 - p1;
vec2 e2 = p0 - p2;

vec2 v0 = p - p0;
vec2 v1 = p - p1;
vec2 v2 = p - p2;

vec2 pq0 = v0 - e0*clamp( dot(v0,e0)/dot(e0,e0), 0.0, 1.0 );
vec2 pq1 = v1 - e1*clamp( dot(v1,e1)/dot(e1,e1), 0.0, 1.0 );
vec2 pq2 = v2 - e2*clamp( dot(v2,e2)/dot(e2,e2), 0.0, 1.0 );

    float s = sign( e0.x*e2.y - e0.y*e2.x );
    vec2 d = min( min( vec2( dot( pq0, pq0 ), s*(v0.x*e0.y-v0.y*e0.x) ),
                       vec2( dot( pq1, pq1 ), s*(v1.x*e1.y-v1.y*e1.x) )),
                       vec2( dot( pq2, pq2 ), s*(v2.x*e2.y-v2.y*e2.x) ));

return -sqrt(d.x)*sign(d.y);
}

float triangle(vec2 p, vec2 a, vec2 b, vec2 c){
float d = distTriangle(p, a, b, c);
    float m = S(0.03, 0.01, d);
    float d2 =  length(a - b);
    m *= S(1.2, 0.8, d2) * 0.5 + S(0.05, 0.03, abs(d2 - 0.75));
    return m;
}

float N21(vec2 p){
p = fract(p * vec2(233.34, 851.73));
    p += dot(p, p + 23.45);
    return fract(p.x * p.y);
}

vec2 N22(vec2 p){
float n = N21(p);
    return vec2(n, N21(p + n));
}

vec2 getPos(vec2 id, vec2 offset){
    vec2 n = N22(id + offset) * iTime;
    return offset + sin(n) * 0.4;
}

float layer(vec2 uv){
vec2 gv = fract(uv) - 0.5;
    vec2 id = floor(uv);

    vec2 p[9];
    int i = 0;
    for(float y = -1.0; y <= 1.0; y++){
    for(float x = -1.0; x <= 1.0; x++){
        p[i++] = getPos(id, vec2(x, y));
    }
    }


    float t = iTime * 10.0;
    float m = 0.0;
    for(int i = 0; i < 9; i++){
    m += line(gv, p[4], p[i]);

        vec2 j = (p[i] - gv) * 20.0;
        float sparkle = 1.0 / dot(j, j);

        m += sparkle * (sin(t + fract(p[i].x) * 10.0) * 0.5 + 0.5);

        for(int yi= i + 1; yi < 9; yi++){
    for(int zi= yi + 1; zi < 9; zi++){

                float len1 = abs(length(p[i] - p[yi]));
                float len2 = abs(length(p[yi] - p[zi]));
                float len3 = abs(length(p[i] - p[zi]));

                if((len1 + len2 + len3) < 2.8){
                m += triangle(gv, p[i], p[yi], p[zi]) * 0.8;
                }
    }
    }
    }
    m += line(gv, p[1], p[3]);
    m += line(gv, p[1], p[5]);
    m += line(gv, p[7], p[3]);
    m += line(gv, p[7], p[5]);

    return m;
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
//get coords and direction
vec2 uv=fragCoord.xy/iResolution.xy-.5;
uv.y*=iResolution.y/iResolution.x;
vec3 dir=vec3(uv*zoom,(iTime*0.002));
float time=iTime*speed+.25;
 float m = 0.0;
    float t = iTime * 0.1;

    float gradient = uv.y;

    float s = sin(t);
    float c = cos(t);
    mat2 rot = mat2(c, -s, s, c);
    uv *= rot;

    for(float i = 0.0; i < 1.0; i += 1.0 / 4.0){
        float z = fract(i + t);
        float size = mix(10.0, 0.5, z);
        float fade = S(0.0, 0.5, z) * S(1.0, 0.8, z);

        m += layer(uv * size + i * 20.0) * fade;
    }


    vec3 base = sin(t * 5.0 * vec3(0.345, 0.456, 0.567)) * 0.4 + 0.6;
    vec3 col = m * base;

    col -= gradient * base;

    fragColor = vec4(col,1.0);
fragCoord = fragCoord - 0.5 * iResolution.xy;
fragColor.rgb = 0.25 * (getColor(fragCoord)
                            + getColor(fragCoord + vec2(0.5, 0.0))
                            + getColor(fragCoord + vec2(0.5, 0.5))
                            + getColor(fragCoord + vec2(0.0, 0.5)));

vec3 from=vec3(1.,.5,0.5)+fragColor.rgb;
from+=vec3(time*2.,time,-2.);


mainVR(fragColor, fragCoord, from, dir);
    fragColor*=vec4(col,1.);
}
