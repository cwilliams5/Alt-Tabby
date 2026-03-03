// Fork of "fate beckons" by vivavolt. https://shadertoy.com/view/Dlj3Dm
// 2023-01-11 09:18:14

// 2953

#define TIME        iTime * 3.

float hf = .01;

#define hsv(h,s,v)  (v) * ( 1. + (s)* clamp(  abs( fract( h + vec3(3,2,1)/3. ) * 6. - 3. ) - 2., -1.,0.) )

vec3 aces_approx(vec3 v) {
  v = max(v, 0.) *.6;
  return min( (v*(2.51*v+.03)) / ( v*(2.43*v+.59)+.14 ), 1.);
}

float pmin(float a, float b, float k) {
  float h = clamp(.5+.5*(b-a)/k, 0., 1.);
  return mix(b, a, h) - k*h*(1.-h);
}

#define pabs(a,k)  - pmin(a, -(a), k)

float height(vec2 p) {
  p *= .4;
  float tm = TIME,
        xm = .5*.005123,
        ym = mix(.125, .25, .5-.5*sin(cos(6.28*TIME/6e2))),
         d = length(p),
         c = 1E6,
         x = pow(d, .1) * ym,
         y = (atan(p.x, p.y)+.05*tm-3.*d) / 6.28;

  for (float v, i = 0.; i < 4.; ++i) {
    v = length(fract(vec2(x - tm*i*xm,
                          fract(y + i*ym)/8.
                         )
                     *16.*( 1. + abs(sin(.01*TIME + 10.)) )
                    )*2.-1.
              );
    c = pmin(c, v, .0125);
  }

  return hf* (pabs(tanh(5.5*d-40.*c*c*d*d*(.55-d))-.25*d, .25) -1.);
}

vec3 normal(vec2 p) {
    vec2 e = vec2(4./iResolution.y, 0);
    return normalize( vec3(
                height(p + e.xy) - height(p - e.xy),
                -2.*e.x,
                height(p + e.yx) - height(p - e.yx)
            ) );
    }

vec3 color(vec2 p) {
  float ss = 1., hh = 1.95, spe  = 3.;

  vec3 lp1 = -vec3( 1, hh, -1) *vec3(ss, 1, ss),
       lp2 = -vec3(-1, hh, -1) *vec3(ss, 1, ss),
     lcol1 = hsv(.1, .75, abs(sin(TIME * .1))*2.),
     lcol2 = hsv(.57, sin(TIME * .1)*.7 , 1.),
       mat = hsv(.55, .83, .55),
         n = normal(p),
        ro = vec3(0, 8, 0),
        pp = vec3(p.x, 0, p.y),
        po = pp,
        rd = normalize( ro - po),
       ld1 = normalize(lp1 - po),
       ld2 = normalize(lp2 - po),
       ref = reflect(rd, n);

  float diff1 = max(dot(n  , ld1), 0.),
        diff2 = max(dot(n  , ld2), 0.),
         ref1 = max(dot(ref, ld1), 0.),
         ref2 = max(dot(ref, ld2), 0.),
           rm = tanh(abs(height(p))*120.);

  vec3 lpow1 = rm*rm*mat*lcol1,
       lpow2 = rm*rm*mat*lcol2;

  return   diff1*diff1*lpow1
         + diff2*diff2*lpow2
         + rm*pow(ref1, spe)*lcol1
         + rm*pow(ref2, spe)*lcol2;
}

void mainImage( out vec4 O, vec2 u ) {
  vec2 R = iResolution.xy,
       p = ( 2.*u - R ) / R.y;

  vec3 col = color(p);
  col = aces_approx(col);
  O = vec4(sqrt(col), 1);
}
