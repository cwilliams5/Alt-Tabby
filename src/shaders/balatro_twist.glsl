#define T iTime
#define white vec3(1)
#define PI 3.141596
#define PI2 PI * 2.

vec2 hash(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)),
             dot(p, vec2(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

float noise(vec2 p) {
    const float K1 = 0.366025404; // (sqrt(3)-1)/2
    const float K2 = 0.211324865; // (3-sqrt(3))/6

    vec2 i = floor(p + (p.x + p.y) * K1);
    vec2 a = p - i + (i.x + i.y) * K2;
    vec2 o = (a.x > a.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    vec2 b = a - o + K2;
    vec2 c = a - 1.0 + 2.0 * K2;

    vec3 h = max(0.5 - vec3(dot(a,a), dot(b,b), dot(c,c)), 0.0);

    vec3 n = h * h * h * h * vec3(
        dot(a, hash(i + 0.0)),
        dot(b, hash(i + o)),
        dot(c, hash(i + 1.0))
    );

    return dot(n, vec3(70.0));
}


float fbm(vec2 p){
  float a = .5;
  float n = 0.;

  for(float i=0.;i<8.;i++){
    n += a * noise(p);
    p *= 2.;
    a *= .5;
  }
  return n;
}

float sdBox( in vec2 p, in vec2 b )
{
    vec2 d = abs(p)-b;
    return length(max(d,0.0)) + min(max(d.x,d.y),0.0);
}

mat2 rotate(float a){
  float s = sin(a);
  float c = cos(a);
  return mat2(c,-s,s,c);
}

vec3 glow(float v, float r, float ins, vec3 col){
  float dist = pow(r/v,ins);
  return 1.-exp(-dist*col);
}

void mainImage(out vec4 O, in vec2 I){
  vec2 R = iResolution.xy;
  vec2 uv = (I*2.-R)/R.y;
  O.rgb *= 0.;;
  O.a = 1.;

  uv *= 2.;
  vec2 p = uv;

  float l = length(uv)-T*0.3;      // 通过length来旋转uv
  p*=rotate(l);
  //p*=rotate(PI*noise(vec2(1,l)));// 试试用距离关联噪音扭曲坐标,效果也不错


  float n = noise(uv);             // 通过噪音来为uv添加偏移
  p += n*.5;


  vec3 c1 = vec3(0.57,0.12,0.1);
  vec3 c2 = vec3(0.153,0.541,0.769);
  // vec3 c1 = vec3(1,0,0);
  // vec3 c2 = vec3(0,0,1);

  n = fbm(p*0.4);                  // 以fbm作为形状
  O.rgb = glow(n, 0.2, 2., c1);

  n = fbm(p*0.2*rotate(.1));      // 蓝色额外添加旋转偏移,以区别
  c2 = glow(n, 0.3, 2., c2);


  // O.rgb = O.rgb + c2;                    // 加法
  // O.rgb = O.rgb - c2;                    // 减法
   O.rgb = O.rgb * c2;                    // 乘法
  // O.rgb = 1. - (1. - O.rgb)*(1. - c2);   // 滤色
  // O.rgb = min(O.rgb, c2);                // 变暗
  // O.rgb = max(O.rgb, c2);                // 变亮
  // O.rgb = abs(O.rgb - c2);               // 差值
  // O.rgb = O.rgb + c2 - 2.*O.rgb*c2;      // 排除
  // O.rgb = mix(O.rgb, c2, 0.5);           // 透明混合
}