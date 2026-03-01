const float pi = 3.1416;

const int steps = 256;
const vec4 background = vec4(vec3(0.0), 1.0);
const float ringRadius = 1.5;
const float pipeRadius = 0.3;

const bool showTexture = false;

vec3 toSRGB(in vec3 color) { return pow(color, vec3(1.0 / 2.2)); }

struct Ray {
  vec3 origin;
  vec3 direction;
};

Ray createRayPerspective(in vec2 resolution, in vec2 screenPosition,
                         in float verticalFov) {
  vec2 topLeft = vec2(-resolution.x, -resolution.y) * .5;
  float z = (resolution.x * .5) / abs(tan(verticalFov / 2.0));

  return Ray(vec3(0.0),
             normalize(vec3(topLeft + screenPosition, -z)));
}

vec3 positionOnRay(in Ray ray, in float t) {
  return ray.origin + ray.direction * t;
}

float sdTorus(in vec3 position, in float ringRadius, in float pipeRadius) {
  vec2 q = vec2(length(position.xz) - ringRadius, position.y);
  return length(q) - pipeRadius;
}

vec2 textureCoordinates(in vec3 position, in float ringRadius) {
  vec2 q = vec2(length(position.xz) - ringRadius, position.y);
  float u = (atan(position.x, position.z) + pi) / (2.0 * pi);
  float v = (atan(q.x, q.y) + pi) / (2.0 * pi);
  return vec2(u, v);
}

float map(in vec3 position) {
  return -sdTorus(position, ringRadius, pipeRadius);
}

float sdSegment(in vec2 point, in vec2 a, in vec2 b) {
  vec2 pa = point - a;
  vec2 ba = b - a;

  float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);

  return length(pa - ba * h);
}

void drawSegment(in vec2 fragmentCoordinates, in vec2 p0, in vec2 p1,
                 in float thickness, in vec4 color, inout vec4 outputColor) {
  float d = sdSegment(fragmentCoordinates, p0, p1);
  float a = 1.0 - clamp(d - thickness / 2.0 + 0.5, 0.0, 1.0);

  outputColor = mix(outputColor, color, a * color.a);
}

vec4 tex(in vec2 uv) {
  vec2 resolution = vec2(400.0);
  uv *= resolution;
  vec4 color = vec4(vec3(0.0), 1.0);

  float thickness = resolution.x / 100.0;

  vec2 position = uv;
  position.x -= position.y - thickness * 3.0 - 2.0;
  position.x = mod(position.x, resolution.x / 8.0);
  position.y = mod(position.y, resolution.x / 30.0);
  drawSegment(position, vec2(2.0, resolution.x / 30.0 * 0.5),
              vec2(resolution.x / 8.0  * 0.5, resolution.x / 30.0 * 0.5),
              thickness * 0.01, vec4(1.0), color);

  vec2 margin = vec2(50.0);
  vec2 offset = vec2(resolution.x + 0.5, 0.5);
  thickness *= 3.0;
  drawSegment(uv, -margin, resolution + margin, thickness * 1.5, vec4(vec3(0.0), 1.0), color);
  drawSegment(uv, -margin, resolution + margin, thickness, vec4(1.0), color);
  drawSegment(uv, -margin - offset, resolution + margin - offset, thickness * 1.5, vec4(vec3(0.0), 1.0), color);
  drawSegment(uv, -margin - offset, resolution + margin - offset, thickness, vec4(1.0), color);
  drawSegment(uv, -margin + offset, resolution + margin + offset, thickness * 1.5, vec4(vec3(0.0), 1.0), color);
  drawSegment(uv, -margin + offset, resolution + margin + offset, thickness, vec4(1.0), color);

  return color;
}

vec4 trace(in Ray ray) {
  ray.origin += vec3(0.0, 1.53, 0.85);

  float t = 0.0;
  for (int i = 0; i < steps; i++) {
    vec3 position = positionOnRay(ray, t).yxz;
    float distance = map(position);

    if (distance < 0.002) {
      vec2 uv = textureCoordinates(position, 1.5);
      uv.x += iTime * 0.1;
      uv.x = mod(uv.x * 10.0, 1.0);
      return tex(uv) * clamp(1.2 - t * 0.25, 0.0, 1.0);
    }

    t += distance * 0.999;
  }

  return background;
}

vec4 takeSample(in vec2 fragCoord) {
  const float fov = pi / 2.0;

  Ray ray = createRayPerspective(iResolution.xy, fragCoord, fov);
  return trace(ray);
}

#define SAMPLE(p) takeSample(p)
vec4 superSample(in vec2 fragCoord, in int samples) {
  if (samples == 1) {
    return SAMPLE(fragCoord);
  }

  float divided = 1.0 / float(samples);

  vec4 outColor = vec4(0.0);
  for (int x = 0; x < samples; x++) {
    for (int y = 0; y < samples; y++) {
      vec2 offset = vec2((float(x) + 0.5) * divided - 0.5,
                         (float(y) + 0.5) * divided - 0.5);
      vec2 samplePosition = fragCoord + offset;
      outColor += SAMPLE(samplePosition);
    }
  }

  return outColor / float(samples * samples);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  if (showTexture) {
    fragColor = tex(fragCoord / iResolution.xy);
    return;
  }

  fragColor = superSample(fragCoord, 2);
  fragColor = vec4(toSRGB(fragColor.rgb), 1.0);
}