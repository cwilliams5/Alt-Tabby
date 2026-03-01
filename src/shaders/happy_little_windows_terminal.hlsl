// CC0: Happy little windows terminal
//  Based on: https://www.shadertoy.com/view/7tVfDV
//  Converted from: https://www.shadertoy.com/view/7tGfW3

cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

#define TIME        time
#define RESOLUTION  float3(resolution, 1.0)
#define PI          3.141592654
#define TAU         (2.0*PI)
#define ROT(a)      float2x2(cos(a), -sin(a), sin(a), cos(a))

#define TOLERANCE       0.0005
#define MAX_RAY_LENGTH  10.0
#define MAX_RAY_MARCHES 60
#define NORM_OFF        0.005

static float g_mod = 2.5;

// License: WTFPL, author: sam hocevar
static const float4 hsv2rgb_K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
float3 hsv2rgb(float3 c) {
  float3 p = abs(frac(c.xxx + hsv2rgb_K.xyz) * 6.0 - hsv2rgb_K.www);
  return c.z * lerp(hsv2rgb_K.xxx, clamp(p - hsv2rgb_K.xxx, 0.0, 1.0), c.y);
}
#define HSV2RGB(c)  (c.z * lerp(hsv2rgb_K.xxx, clamp(abs(frac(c.xxx + hsv2rgb_K.xyz) * 6.0 - hsv2rgb_K.www) - hsv2rgb_K.xxx, 0.0, 1.0), c.y))

static const float hoff = 0.;

static const float3 skyCol     = HSV2RGB(float3(hoff+0.50, 0.90, 0.25));
static const float3 skylineCol = HSV2RGB(float3(hoff+0.70, 0.95, 0.5));
static const float3 sunCol     = HSV2RGB(float3(hoff+0.80, 0.90, 0.5));
static const float3 diffCol1   = HSV2RGB(float3(hoff+0.75, 0.90, 0.5));
static const float3 diffCol2   = HSV2RGB(float3(hoff+0.95, 0.90, 0.5));

static const float3 sunDir1    = normalize(float3(0., 0.05, -1.0));

static const float lpf = 5.0;
static const float3 lightPos1  = lpf*float3(+1.0, 2.0, 3.0);
static const float3 lightPos2  = lpf*float3(-1.0, 2.0, 3.0);

// License: Unknown, author: nmz (twitter: @stormoid)
float3 sRGB(float3 t) {
  return lerp(1.055*pow(t, (float3)(1./2.4)) - 0.055, 12.92*t, step(t, (float3)0.0031308));
}

// License: Unknown, author: Matt Taylor
float3 aces_approx(float3 v) {
  v = max(v, 0.0);
  v *= 0.6f;
  float a = 2.51f;
  float b = 0.03f;
  float c = 2.43f;
  float d = 0.59f;
  float e = 0.14f;
  return clamp((v*(a*v+b))/(v*(c*v+d)+e), 0.0f, 1.0f);
}

float tanh_approx(float x) {
  float x2 = x*x;
  return clamp(x*(27.0 + x2)/(27.0+9.0*x2), -1.0, 1.0);
}

// License: MIT, author: Inigo Quilez
float rayPlane(float3 ro, float3 rd, float4 p) {
  return -(dot(ro,p.xyz)+p.w)/dot(rd,p.xyz);
}

// License: MIT, author: Inigo Quilez
float box(float2 p, float2 b) {
  float2 d = abs(p)-b;
  return length(max(d,0.0)) + min(max(d.x,d.y),0.0);
}

float3 render0(float3 ro, float3 rd) {
  float3 col = (float3)0;
  float sf = 1.0001-max(dot(sunDir1, rd), 0.0);
  col += skyCol*pow((1.0-abs(rd.y)), 8.0);
  col += (lerp(0.0025, 0.125, tanh_approx(.005/sf))/abs(rd.y))*skylineCol;
  sf *= sf;
  col += sunCol*0.00005/sf;

  float tp1  = rayPlane(ro, rd, float4(float3(0.0, -1.0, 0.0), 6.0));

  if (tp1 > 0.0) {
    float3 pos  = ro + tp1*rd;
    float2 pp = pos.xz;
    float db = box(pp, float2(5.0, 9.0))-3.0;

    col += (float3)4.0*skyCol*rd.y*rd.y*smoothstep(0.25, 0.0, db);
    col += (float3)0.8*skyCol*exp(-0.5*max(db, 0.0));
  }

  return clamp(col, 0.0, 10.0);
}

float df(float3 p) {
  float3 p0 = p;
  p0.xy = mul(ROT(0.2*p0.z-0.1*TIME), p0.xy);
  float d = -box(p0.xy, float2(g_mod, 1.25));
  return d;
}

float3 calcNormal(float3 pos) {
  float2 eps = float2(NORM_OFF, 0.0);
  float3 nor;
  nor.x = df(pos+eps.xyy) - df(pos-eps.xyy);
  nor.y = df(pos+eps.yxy) - df(pos-eps.yxy);
  nor.z = df(pos+eps.yyx) - df(pos-eps.yyx);
  return normalize(nor);
}

float rayMarch(float3 ro, float3 rd, float initt) {
  float t = initt;
  for (int i = 0; i < MAX_RAY_MARCHES; ++i) {
    if (t > MAX_RAY_LENGTH) {
      t = MAX_RAY_LENGTH;
      break;
    }
    float d = df(ro + rd*t);
    if (d < TOLERANCE) {
      break;
    }
    t += d;
  }
  return t;
}

float3 boxCol(float3 col, float3 nsp, float3 ro, float3 rd, float3 nnor, float3 nrcol) {
  float nfre  = 1.0+dot(rd, nnor);
  nfre        *= nfre;

  float3 nld1   = normalize(lightPos1-nsp);
  float3 nld2   = normalize(lightPos2-nsp);

  float ndif1 = max(dot(nld1, nnor), 0.0);
  ndif1       *= ndif1;

  float ndif2 = max(dot(nld2, nnor), 0.0);
  ndif2       *= ndif2;

  float3 scol = (float3)0;
  scol += diffCol1*ndif1;
  scol += diffCol2*ndif2;
  scol += 0.1*(skyCol+skylineCol);
  scol += nrcol*0.75*lerp((float3)0.25, float3(0.5, 0.5, 1.0), nfre);

  float3 pp = nsp-ro;

  col = lerp(col, scol, smoothstep(100.0, 20.0, dot(pp, pp)));

  return col;
}

float3 render1(float3 ro, float3 rd) {
  float3 col = 0.1*sunCol;

  float nt    = rayMarch(ro, rd, 0.0);
  if (nt < MAX_RAY_LENGTH) {
    float3 nsp    = ro + rd*nt;
    float3 nnor   = calcNormal(nsp);

    float3 nref   = reflect(rd, nnor);
    float nrt   = rayMarch(nsp, nref, 0.2);
    float3 nrcol  = render0(nsp, nref);

    if (nrt < MAX_RAY_LENGTH) {
      float3 nrsp   = nsp + nref*nrt;
      float3 nrnor  = calcNormal(nrsp);
      float3 nrref  = reflect(nref, nrnor);
      nrcol = boxCol(nrcol, nrsp, ro, nref, nrnor, render0(nrsp, nrref));
    }

    col = boxCol(col, nsp, ro, rd, nnor, nrcol);
  }

  return col;
}

float3 effect(float2 p) {
  const float fov = tan(TAU/(6.-0.6));
  const float3 up = float3(0.0, 1.0, 0.0);
  const float3 ro = float3(0.0, 0.0, 5.0);
  const float3 la = float3(0.0, 0.0, 0.);

  float3 ww = normalize(la - ro);
  float3 uu = normalize(cross(up, ww));
  float3 vv = cross(ww,uu);
  float3 rd = normalize(-p.x*uu + p.y*vv + fov*ww);

  float3 col = render1(ro, rd);

  return col;
}

float4 PSMain(PSInput input) : SV_Target {
  float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);
  float2 q = fragCoord/RESOLUTION.xy;
  float2 p = -1. + 2. * q;
  p.x *= RESOLUTION.x/RESOLUTION.y;
  g_mod = lerp(1.25, 2.5, 0.5+0.5*sin(TAU*TIME/66.0));
  float3 col = effect(p);
  // Saturate colors
  col -= 0.0333*float3(1.0, 2.0, 2.0);
  col = aces_approx(col);
  col = sRGB(col);

  // Darken/desaturate post-processing
  float lum = dot(col, float3(0.299, 0.587, 0.114));
  col = lerp(col, (float3)lum, desaturate);
  col = col * (1.0 - darken);

  // Alpha from brightness, premultiply
  float a = max(col.r, max(col.g, col.b));
  return float4(col * a, a);
}
