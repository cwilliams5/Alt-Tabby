// Fork of "cutting words" by vivavolt. https://shadertoy.com/view/mtXGWB
// 2022-12-29 12:00:41

// Fork of "Windows Terminal Damask Rose" by mrange. https://shadertoy.com/view/flKfzh
// 2022-12-29 11:48:36

// CC0: Windows Terminal Damask Rose
//  Been tinkering creating Windows Terminal shaders
//  Created this as a version of an earlier shader
//  Thought it turned out decent so sharing

// Define to use a faster atan implementation
//  Introduces slight assymmetries that don't look outright terrible at least
//#define FASTATAN

#define TIME        iTime * 3.
#define RESOLUTION  iResolution
#define PI          3.141592654
#define PI_2        (0.5*PI)
#define TAU         (2.0*PI)
#define ROT(a)      mat2(cos(a), sin(a), -sin(a), cos(a))


#if defined(FASTATAN)
#define ATAN atan_approx
#else
#define ATAN atan
#endif

const float hf = 0.01;

// License: WTFPL, author: sam hocevar, found: https://stackoverflow.com/a/17897228/418488
const vec4 hsv2rgb_K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
vec3 hsv2rgb(vec3 c) {
  vec3 p = abs(fract(c.xxx + hsv2rgb_K.xyz) * 6.0 - hsv2rgb_K.www);
  return c.z * mix(hsv2rgb_K.xxx, clamp(p - hsv2rgb_K.xxx, 0.0, 1.0), c.y);
}
// License: WTFPL, author: sam hocevar, found: https://stackoverflow.com/a/17897228/418488
//  Macro version of above to enable compile-time constants
#define HSV2RGB(c)  (c.z * mix(hsv2rgb_K.xxx, clamp(abs(fract(c.xxx + hsv2rgb_K.xyz) * 6.0 - hsv2rgb_K.www) - hsv2rgb_K.xxx, 0.0, 1.0), c.y))

// License: Unknown, author: nmz (twitter: @stormoid), found: https://www.shadertoy.com/view/NdfyRM
vec3 sRGB(vec3 t) {
  return mix(1.055*pow(t, vec3(1./2.4)) - 0.055, 12.92*t, step(t, vec3(0.0031308)));
}

// License: Unknown, author: Matt Taylor (https://github.com/64), found: https://64.github.io/tonemapping/
vec3 aces_approx(vec3 v) {
  v = max(v, 0.0);
  v *= 0.6f;
  float a = 2.51f;
  float b = 0.03f;
  float c = 2.43f;
  float d = 0.59f;
  float e = 0.14f;
  return clamp((v*(a*v+b))/(v*(c*v+d)+e), 0.0f, 1.0f);
}

// License: Unknown, author: Unknown, found: don't remember
float tanh_approx(float x) {
//  return tanh(x);
  float x2 = x*x;
  return clamp(x*(27.0 + x2)/(27.0+9.0*x2), -1.0, 1.0);
}

// License: MIT, author: Pascal Gilcher, found: https://www.shadertoy.com/view/flSXRV
float atan_approx(float y, float x) {
  float cosatan2 = x / (abs(x) + abs(y));
  float t = PI_2 - cosatan2 * PI_2;
  return y < 0.0 ? -t : t;
}

// License: MIT, author: Inigo Quilez, found: https://www.iquilezles.org/www/articles/smin/smin.htm
float pmin(float a, float b, float k) {
  float h = clamp(0.5+0.5*(b-a)/k, 0.0, 1.0);
  return mix(b, a, h) - k*h*(1.0-h);
}

float pabs(float a, float k) {
  return -pmin(a, -a, k);
}

float height(vec2 p) {
//  float tm = TIME-2.*length(p);
  float tm = TIME;
  const float xm = 0.5*0.005123;
  float ym = mix(0.125, 0.25, 0.5-0.5*sin(cos(TAU*TIME/600.0)));

  p *= 0.4;

  float d = length(p);
  float c = 1E6;
  float x = pow(d, 0.1);
  float y = (ATAN(p.x, p.y)+0.05*tm-2.0*d) / TAU;

  for (float i = 0.; i < 4.; ++i) {
    float v = length(fract(vec2(x - tm*i*xm, fract(y + i*ym)*.125)*16.)*2.-1.);
    c = pmin(c, v, 0.0125);
  }

  float h =  (-hf+hf*(pabs(tanh_approx(5.5*d-40.*c*c*d*d*(.55-d))-0.25*d, 0.25)));
  return h;
}

vec3 normal(vec2 p) {
  vec2 e = vec2(4.0/RESOLUTION.y, 0);

  vec3 n;
  n.x = height(p + e.xy) - height(p - e.xy);
  n.y = -2.0*e.x;
  n.z = height(p + e.yx) - height(p - e.yx);

  return normalize(n);
}

vec3 color(vec2 p) {
  const float ss = 1.;
  const float hh = 1.95;

  const vec3 lp1 = -vec3(1.0 , hh, -1.0)*vec3(ss, 1.0, ss);
  const vec3 lp2 = -vec3(-1.0, hh, -1.0)*vec3(ss, 1.0, ss);

  const vec3 lcol1 = HSV2RGB(vec3(0.70, 0.55, 2.0));
  const vec3 lcol2 = HSV2RGB(vec3(0.67, 0.7 , 1.0));
  const vec3 mat   = HSV2RGB(vec3(0.55, 0.5, 0.05));
  const float spe  = 7.0;

  float h = height(p);
  vec3  n = normal(p);

  vec3 ro = vec3(0.0, 8.0, 0.0);
  vec3 pp = vec3(p.x, 0.0, p.y);

  vec3 po = vec3(p.x, 0.0, p.y);
  vec3 rd = normalize(ro - po);

  vec3 ld1 = normalize(lp1 - po);
  vec3 ld2 = normalize(lp2 - po);

  float diff1 = max(dot(n, ld1), 0.0);
  float diff2 = max(dot(n, ld2), 0.0);

  vec3  rn    = n;
  vec3  ref   = reflect(rd, rn);
  float ref1  = max(dot(ref, ld1), 0.0);
  float ref2  = max(dot(ref, ld2), 0.0);

  float dm = tanh_approx(abs(h)*120.0);
  float rm = dm;
  dm *= dm;

  vec3 lpow1 = dm*mat*lcol1;
  vec3 lpow2 = dm*mat*lcol2;

  vec3 col = vec3(0.0);
  col += diff1*diff1*lpow1;
  col += diff2*diff2*lpow2;

  col += rm*pow(ref1, spe)*lcol1;
  col += rm*pow(ref2, spe)*lcol2;

  return col;
}

void mainImage( out vec4 fragColor, in vec2 fragCoord ) {
  vec2 q = fragCoord/RESOLUTION.xy;
  vec2 p = -1. + 2. * q;
  p.x *= RESOLUTION.x/RESOLUTION.y;
  vec3 col = color(p);

  col = aces_approx(col);
  col = sRGB(col);

  fragColor = vec4(col, 1.0);
}