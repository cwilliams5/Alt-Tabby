// cosine based palette, 4 vec3 params
vec3 palette( in float t, in vec3 a, in vec3 b, in vec3 c, in vec3 d )
{
    return a + b*cos( 6.28318*(c*t+d) );
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    // Normalized pixel coordinates (from 0 to 1)
    vec2 uv = fragCoord/iResolution.xy;

    float time = iTime*0.2;

    // Calculate two points on screen.

    vec2 c1 = vec2(sin(time)*0.5, cos(iTime)*0.7);
    vec2 c2 = vec2(sin(time*0.7)*0.9, cos(iTime*0.65)*0.6);

    //Determine length to point 1 & calculate color.
    float d1 = length( uv - c1);
    vec3 col1 = palette( d1+time,vec3(0.5,0.5,0.5),vec3(0.5,0.5,0.5),vec3(1.0,1.0,1.0),vec3(0.0,0.33,0.67));

    //Determine length to point 2 & calculate color.
    float d2 = length( uv - c2);
    vec3 col2 = palette( d2+time,vec3(0.5,0.5,0.5),vec3(0.5,0.5,0.5),vec3(1.0,1.0,1.0),vec3(0.0,0.33,0.67));


    // Output to screen
    fragColor = vec4( (col1+col2) / 2.0 ,1.0);
}