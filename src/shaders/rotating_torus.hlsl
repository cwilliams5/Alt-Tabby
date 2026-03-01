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

static const float pi = 3.1416;

static const int steps = 256;
static const float4 background = float4((float3)0.0, 1.0);
static const float ringRadius = 1.5;
static const float pipeRadius = 0.3;

float3 toSRGB(float3 color) { return pow(color, (float3)(1.0 / 2.2)); }

struct Ray {
    float3 origin;
    float3 direction;
};

Ray createRayPerspective(float2 res, float2 screenPosition, float verticalFov) {
    float2 topLeft = float2(-res.x, -res.y) * 0.5;
    float z = (res.x * 0.5) / abs(tan(verticalFov / 2.0));

    Ray r;
    r.origin = (float3)0.0;
    r.direction = normalize(float3(topLeft + screenPosition, -z));
    return r;
}

float3 positionOnRay(Ray ray, float t) {
    return ray.origin + ray.direction * t;
}

float sdTorus(float3 position, float rRadius, float pRadius) {
    float2 q = float2(length(position.xz) - rRadius, position.y);
    return length(q) - pRadius;
}

float2 textureCoordinates(float3 position, float rRadius) {
    float2 q = float2(length(position.xz) - rRadius, position.y);
    float u = (atan2(position.x, position.z) + pi) / (2.0 * pi);
    float v = (atan2(q.x, q.y) + pi) / (2.0 * pi);
    return float2(u, v);
}

float map(float3 position) {
    return -sdTorus(position, ringRadius, pipeRadius);
}

float sdSegment(float2 pt, float2 a, float2 b) {
    float2 pa = pt - a;
    float2 ba = b - a;

    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);

    return length(pa - ba * h);
}

void drawSegment(float2 fragmentCoordinates, float2 p0, float2 p1,
                 float thickness, float4 color, inout float4 outputColor) {
    float d = sdSegment(fragmentCoordinates, p0, p1);
    float a = 1.0 - clamp(d - thickness / 2.0 + 0.5, 0.0, 1.0);

    outputColor = lerp(outputColor, color, a * color.a);
}

float4 tex(float2 uv) {
    float2 res = (float2)400.0;
    uv *= res;
    float4 color = float4((float3)0.0, 1.0);

    float thickness = res.x / 100.0;

    float2 position = uv;
    position.x -= position.y - thickness * 3.0 - 2.0;
    position.x = fmod(position.x, res.x / 8.0);
    position.y = fmod(position.y, res.x / 30.0);
    drawSegment(position, float2(2.0, res.x / 30.0 * 0.5),
                float2(res.x / 8.0 * 0.5, res.x / 30.0 * 0.5),
                thickness * 0.01, (float4)1.0, color);

    float2 margin = (float2)50.0;
    float2 offset = float2(res.x + 0.5, 0.5);
    thickness *= 3.0;
    drawSegment(uv, -margin, res + margin, thickness * 1.5, float4((float3)0.0, 1.0), color);
    drawSegment(uv, -margin, res + margin, thickness, (float4)1.0, color);
    drawSegment(uv, -margin - offset, res + margin - offset, thickness * 1.5, float4((float3)0.0, 1.0), color);
    drawSegment(uv, -margin - offset, res + margin - offset, thickness, (float4)1.0, color);
    drawSegment(uv, -margin + offset, res + margin + offset, thickness * 1.5, float4((float3)0.0, 1.0), color);
    drawSegment(uv, -margin + offset, res + margin + offset, thickness, (float4)1.0, color);

    return color;
}

float4 trace(Ray ray) {
    ray.origin += float3(0.0, 1.53, 0.85);

    float t = 0.0;
    for (int i = 0; i < steps; i++) {
        float3 position = positionOnRay(ray, t).yxz;
        float distance = map(position);

        if (distance < 0.002) {
            float2 uv = textureCoordinates(position, 1.5);
            uv.x += time * 0.1;
            uv.x = fmod(uv.x * 10.0, 1.0);
            return tex(uv) * clamp(1.2 - t * 0.25, 0.0, 1.0);
        }

        t += distance * 0.999;
    }

    return background;
}

float4 takeSample(float2 fragCoord) {
    float fov = pi / 2.0;

    Ray ray = createRayPerspective(resolution, fragCoord, fov);
    return trace(ray);
}

float4 superSample(float2 fragCoord, int samples) {
    if (samples == 1) {
        return takeSample(fragCoord);
    }

    float divided = 1.0 / (float)samples;

    float4 outColor = (float4)0.0;
    for (int x = 0; x < samples; x++) {
        for (int y = 0; y < samples; y++) {
            float2 offset = float2(((float)x + 0.5) * divided - 0.5,
                                   ((float)y + 0.5) * divided - 0.5);
            float2 samplePosition = fragCoord + offset;
            outColor += takeSample(samplePosition);
        }
    }

    return outColor / (float)(samples * samples);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float4 fragColor = superSample(fragCoord, 2);
    float3 color = toSRGB(fragColor.rgb);

    // Darken/desaturate
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}