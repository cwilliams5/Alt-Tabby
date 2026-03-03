// Thanks to gPlati for the line function: https://www.shadertoy.com/view/MlcGDB
// -- -- -- -- -- --
// Otherwise:
// - Brendon Schumacker
// www.bschu.net


float line(vec2 P, vec2 A, vec2 B, float r) {
	vec2 g = B - A;
    float d = abs(dot(normalize(vec2(g.y, -g.x)), P - A));
	return smoothstep(r, 0.5*r, d);
}


void mainImage( out vec4 fragColor, in vec2 fragCoord ) {

    vec2 uv = fragCoord/iResolution.xy;

    // Please wear a helmet if you
    // uncomment these following lines.

    // --- You've been warned ---
    // -- Use at your own risk --

    //uv.x += sin(iTime);
    //uv.y += -sin(iTime);

    // Some colors for testing.
    vec3 black = vec3(0.,0.,0.);
    vec3 white = vec3(1.,1.,1.);
    vec3 red = vec3(1.,0.,0.);
    vec3 blue = vec3(0.3,0.3,1.0);
    vec3 grey = vec3(0.2,0.2,0.2);

    // A fancy changing color.
    float r = abs(sin(iTime/2.));
    float g = abs(cos(iTime/3.));
    float b = abs(-sin(iTime/4.));

    // Esbalish the colors.
    vec3 changing = vec3(r,g,b);
    //vec3 color = black;
    vec3 color = vec3(abs(cos(iTime/2.))-0.8);

    // points for our lines
    float speed = 0.3;
    float x1 = sin(iTime*speed);
    float x2 = cos(iTime*speed);
    float y1 = sin(iTime*speed);
    float y2 = cos(iTime*speed);

    float l = 0.0;
    float amount = 100.;
    float width = 0.005;

    for (float i = -amount; i < amount; i += 1.0) {
        float start = i * 0.05;
        l = line(uv, vec2(x1+start,y1-start), vec2(x2+start,y2), width);
        color = (1.0-l)*color + (l*changing);
    }

    fragColor = vec4(color,1.0);

}
