#define MAXDIST 500.

float f = 1.;

struct obj
{
    vec3 loc;
    float size_max;
    int type;
    vec4 size;
};

obj objs[5];

float getDist(vec3 pt, obj object)
{
    return 1.;
}
float getDist(vec3 pt)
{
    float d[objs.length()];
    for (int i = 0; i<objs.length(); i++)
        d[i]=getDist(pt,objs[i]);
    float mind = MAXDIST;

    for (int i = 0; i<objs.length(); i++)
        if (mind>d[i])
            mind=d[i];
    return mind;
}

float getLight(vec3 pt)
{
    return pt.z-1.;
}

vec3 getColor(vec3 pt)
{
    pt.z=pt.x+pt.y*.3;
    return 0.5 + 0.5*cos((.3*iTime*vec3(1.,.95,1.06))+pt.xyz*.2);;
}

float march(vec3 origin, vec3 dir, float maxdist)
{
    return f;
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    // Normalized pixel coordinates (to -1 to 1)
    vec2 uv = (fragCoord-.5*iResolution.xy)/iResolution.y;

    // Camera location & look direction
    vec3 cam = vec3(0,0,1);
    vec3 look = normalize(vec3(uv.x, uv.y, 1));

    float d = march(cam,look,MAXDIST);
    vec3 pt = cam+d*look;
    vec3 col = getLight(pt)*getColor(pt);

    // Time varying pixel color
    //vec3 col = 0.5 + 0.5*cos(iTime+uv.xyx+vec3(0,2,4));

    // Output to screen
    fragColor.xyz = col.xyz;
}