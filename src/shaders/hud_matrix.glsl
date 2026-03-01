#define PI 3.14159265359
#define S(a,b,t) smoothstep(a,b,t)

float hash(float n){ return fract(sin(n)*43758.5453123); }
float hash21(vec2 p){ return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453); }

float bandMaskHard(float y, float y0, float thick)
{
    return step(abs(y - y0), thick);
}

float glyph(vec2 uv, float id)
{
    uv *= vec2(5.0,7.0);
    vec2 gv = floor(uv);
    vec2 lv = fract(uv);

    float h = hash21(gv + id*13.1);
    float on = step(0.55, h);

    float edge = S(0.1,0.0,min(min(lv.x,1.0-lv.x),min(lv.y,1.0-lv.y)));
    return on * edge;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec2 uv0 = fragCoord.xy / iResolution.xy;
    vec2 uv  = uv0*0.64;

    uv.x *= iResolution.x / iResolution.y;

    // ---------------- SCROLL ----------------
    float scrollSpeed = 0.128;
    uv.y += iTime * scrollSpeed;

    float row = floor(uv.y * 20.0);
    float col = floor(uv.x * 30.0);

    vec2 cell = vec2(col,row);
    float id  = hash21(cell);

    vec2 localUV = fract(vec2(uv.x*30.0, uv.y*20.0));

    // ---------------- GLITCH ----------------
    float t = floor(iTime * 14.0);

    float glitchCount     = 3.0;
    float glitchThickness = 0.02;
    float glitchOffset    = 0.25;

    float globalGate = step(3.45, hash(t*2.1));

    vec2 uvGlitch = uv;

    for(float i=0.0;i<glitchCount;i++)
    {
        float gid = i + t*17.13;

        float y0  = hash(gid) * 2.0 - 1.0;
        float dir = (hash(gid*3.7) < 0.5) ? -1.0 : 1.0;
        float power = mix(0.3,1.0,hash(gid*9.1));

        float m = bandMaskHard(uv.y*2.0-1.0, y0, glitchThickness);

        uvGlitch.x += globalGate * m * dir * glitchOffset * power;
    }

    vec2 localGlitch = fract(vec2(uvGlitch.x*36.0, uvGlitch.y*24.0));

    float gR = glyph(localGlitch + vec2(0.01,0.0), id);
    float gG = glyph(localGlitch, id);
    float gB = glyph(localGlitch - vec2(0.01,0.0), id);

    // depth fade
    float fade = exp(-uv.x * 0.8);

    // flicker
    float flick = 0.85 + 0.25*sin(iTime*8.0 + row);

    vec3 colOut = vec3(gR*0.3, gG*0.8, gB*0.7) * fade * flick;

    // random flash burst
    colOut *= 1.0 + 0.5 * step(0.94, hash(t*5.7));

    fragColor = vec4(colOut,1.0);
}
