// Brainfall by panna_pudi
// https://www.shadertoy.com/view/XXG3zG
// Just wanted to play with one of the old Shane's shaders
// https://www.shadertoy.com/view/XlBXWw

const float PI = acos(-1.);
const float TAU = 2. * PI;

// First time using this tonemapping curve
// https://github.com/KhronosGroup/ToneMapping/blob/main/PBR_Neutral/pbrNeutral.glsl
vec3 PBRNeutralToneMapping(vec3 color) {
    const float startCompression = 0.8 - 0.04;
    const float desaturation = 0.15;

    float x = min(color.r, min(color.g, color.b));
    float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
    color -= offset;

    float peak = max(color.r, max(color.g, color.b));
    if (peak < startCompression)
        return color;

    const float d = 1. - startCompression;
    float newPeak = 1. - d * d / (peak + d - startCompression);
    color *= newPeak / peak;

    float g = 1. - 1. / (desaturation * (peak - newPeak) + 1.);
    return mix(color, newPeak * vec3(1, 1, 1), g);
}

mat2 rot(float x) {
    float c = cos(x), s = sin(x);
    return mat2(c, -s, s, c);
}

// https://www.shadertoy.com/view/clXXDl
float zuzoise(vec2 uv, float t) {
    vec2 sine_acc = vec2(0.);
    vec2 res = vec2(0.);
    float scale = 5.;

    mat2 m = rot(1.);

    for (float i = 0.; i < 15.; i++) {
        uv *= m;
        sine_acc *= m;
        vec2 layer = uv * scale * i + sine_acc - t;
        sine_acc += sin(layer);
        res += (cos(layer) * 0.5 + 0.5) / scale;
        scale *= (1.2);
    }
    return dot(res, vec2(1.));
}

void mainImage( out vec4 fragColor, in vec2 fragCoord ) {
    vec2 uv = (fragCoord/iResolution.xy - 0.5)
              * vec2(iResolution.x / iResolution.y, 1.);
    uv *= .2;

    float t = iTime;

    float a = sin(t * .1) * sin(t * .13 + dot(uv,uv) * 1.5) * 4.;
    uv *= rot(a);

    vec3 sp = vec3(uv, 0.);

    const float L = 7.;
    const float gfreq = .7;
    float sum = 0.;

    float th = PI * 0.7071 / L;
    float cs = cos(th), si = sin(th);
    mat2 M = mat2(cs, -si, si, cs);

    vec3 col = vec3(0);

    float f = 0.;
    vec2 offs = vec2(.2);

    for (float i = 0.; i < L; i++) {
        float s = fract((i - t * 2.) / L);
        float e = exp2(s * L) * gfreq;

        float a = (1. - cos(s * TAU)) / 3.;

        float t = t * 3.;
        t = t - sin(t * 1.);
        f += zuzoise(M * sp.xy * e + offs, t) * a;

        sum += a;

        M *= M;
    }

    sum = max(sum, .001);

    f /= sum;

    col = vec3(1., 0., 0.5) * smoothstep(1.37, 1.5, f);
    col += vec3(0., 1., 0.5) * pow(smoothstep(1., 1.54, f), 10.);
    col += vec3(0.20, 0.20, 0.20) * smoothstep(0., 4.59, f - 0.12);

    col = PBRNeutralToneMapping(col);

    col = pow(col, vec3(0.4545));

    // Output to screen
    fragColor = vec4(col, 1.0);
}
