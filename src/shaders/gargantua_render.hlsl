cbuffer Constants : register(b0) {
    float time;
    float2 resolution;
    float timeDelta;
    uint frame;
    float darken;
    float desaturate;
    float _pad;
};

Texture2D iChannel0 : register(t0);
SamplerState samp0 : register(s0);
Texture2D iChannel1 : register(t1);
SamplerState samp1 : register(s1);

struct PSInput {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

// Constants
#define PI          3.1415926
#define TWO_PI      6.2831852
#define HALF_PI     1.5707963
#define EPSILON_C   0.00001
#define IN_RANGE(x,a,b)     (((x) > (a)) && ((x) < (b)))

// Reduced SPP for real-time performance
#define SPP 2
#define GRAVITATIONAL_LENSING

struct Ray {
    float3 origin;
    float3 dir;
};

struct Camera {
    float3x3 rotate;
    float3 pos;
    float3 target;
    float fovV;
};

struct BlackHole {
    float3 position_;
    float radius_;
    float ring_radius_inner_;
    float ring_radius_outer_;
    float ring_thickness_;
    float mass_;
};

static float seed;
static BlackHole gargantua;
static Camera camera;

float rnd() { return frac(sin(seed++)*43758.5453123); }

void initScene() {
    gargantua.position_ = float3(0.0, 0.0, -8.0);
    gargantua.radius_ = 0.1;
    gargantua.ring_radius_inner_ = gargantua.radius_ + 0.8;
    gargantua.ring_radius_outer_ = 6.0;
    gargantua.ring_thickness_ = 0.15;
    gargantua.mass_ = 1000.0;
}

void initCamera(float3 pos, float3 target, float3 upDir, float fovV) {
    float3 back = normalize(pos - target);
    float3 right = normalize(cross(upDir, back));
    float3 up = cross(back, right);
    camera.rotate[0] = right;
    camera.rotate[1] = up;
    camera.rotate[2] = back;
    camera.fovV = fovV;
    camera.pos = pos;
}

float3 sphericalToCartesian(float rho, float phi, float theta) {
    float sinTheta = sin(theta);
    return float3(sinTheta*cos(phi), sinTheta*sin(phi), cos(theta)) * rho;
}

void cartesianToSpherical(float3 xyz, out float rho, out float phi, out float theta) {
    rho = sqrt(xyz.x * xyz.x + xyz.y * xyz.y + xyz.z * xyz.z);
    phi = asin(xyz.y / rho);
    theta = atan2(xyz.z, xyz.x);
}

Ray genRay(float2 pixel) {
    Ray ray;
    float2 iPlaneSize = 2.0 * tan(0.5 * camera.fovV) * float2(resolution.x / resolution.y, 1.0);
    float2 ixy = (pixel / resolution.xy - 0.5) * iPlaneSize;
    ray.origin = camera.pos;
    ray.dir = mul(normalize(float3(ixy.x, ixy.y, -1.0)), camera.rotate);
    return ray;
}

float noise(float3 x) {
    float3 p = floor(x);
    float3 f = frac(x);
    f = f * f * (3.0 - 2.0 * f);
    float2 uv = (p.xy + float2(37.0, 17.0) * p.z) + f.xy;
    float2 rg = iChannel0.SampleLevel(samp0, (uv + 0.5) / 256.0, 0.0).yx;
    return -1.0 + 2.0 * lerp(rg.x, rg.y, f.z);
}

float map5(float3 p) {
    float3 q = p;
    float f;
    f  = 0.50000 * noise(q); q = q * 2.02;
    f += 0.25000 * noise(q); q = q * 2.03;
    f += 0.12500 * noise(q); q = q * 2.01;
    f += 0.06250 * noise(q); q = q * 2.02;
    f += 0.03125 * noise(q);
    return clamp(1.5 - p.y - 2.0 + 1.75 * f, 0.0, 1.0);
}

// Stars from nimitz - https://www.shadertoy.com/view/ltfGDs
float tri(float x) { return abs(frac(x) - 0.5); }

float3 hash33(float3 p) {
    p = frac(p * float3(5.3983, 5.4427, 6.9371));
    p += dot(p.yzx, p.xyz + float3(21.5351, 14.3137, 15.3219));
    return frac(float3(p.x * p.z * 95.4337, p.x * p.y * 97.597, p.y * p.z * 93.8365));
}

float3 stars(float3 p) {
    float fov = radians(50.0);
    float3 c = (float3)0;
    float res = resolution.x * 0.85 * fov;

    p.x += (tri(p.z * 50.0) + tri(p.y * 50.0)) * 0.006;
    p.y += (tri(p.z * 50.0) + tri(p.x * 50.0)) * 0.006;
    p.z += (tri(p.x * 50.0) + tri(p.y * 50.0)) * 0.006;

    for (float i = 0.0; i < 3.0; i++) {
        float3 q = frac(p * (0.15 * res)) - 0.5;
        float3 id = floor(p * (0.15 * res));
        float rn = hash33(id).z;
        float c2 = 1.0 - smoothstep(-0.2, 0.4, length(q));
        c2 *= step(rn, 0.005 + i * 0.014);
        c += c2 * (lerp(float3(1.0, 0.75, 0.5), float3(0.85, 0.9, 1.0), rn * 30.0) * 0.5 + 0.5);
        p *= 1.15;
    }
    return c * c * 1.5;
}

float3 getBgColor(float3 dir) {
    float rho, phi, theta;
    cartesianToSpherical(dir, rho, phi, theta);
    float2 uv = float2(phi / PI, theta / TWO_PI);
    float3 c0 = iChannel1.Sample(samp1, uv).xyz * 0.3;
    float3 c1 = stars(dir);
    return c0.bgr * 0.4 + c1 * 2.0;
}

void getCloudColorAndDensity(float3 p, float t, out float4 color, out float density) {
    float d2 = dot(p, p);
    color = (float4)0;

    if (sqrt(d2) < gargantua.radius_) {
        density = 0.0;
    } else {
        float rho, phi, theta;
        cartesianToSpherical(p, rho, phi, theta);
        rho = (rho - gargantua.ring_radius_inner_) / (gargantua.ring_radius_outer_ - gargantua.ring_radius_inner_);

        if (!IN_RANGE(p.y, -gargantua.ring_thickness_, gargantua.ring_thickness_) ||
            !IN_RANGE(rho, 0.0, 1.0)) {
            density = 0.0;
        } else {
            float cloudX = sqrt(rho);
            float cloudY = ((p.y - gargantua.position_.y) + gargantua.ring_thickness_) / (2.0 * gargantua.ring_thickness_);
            float cloudZ = theta / TWO_PI;

            float blending = 1.0;
            blending *= lerp(rho * 5.0, 1.0 - (rho - 0.2) / (0.8 * rho), rho > 0.2 ? 1.0 : 0.0);
            blending *= lerp(cloudY * 2.0, 1.0 - (cloudY - 0.5) * 2.0, cloudY > 0.5 ? 1.0 : 0.0);

            float3 moving = float3(t * 0.5, 0.0, t * rho * 0.1);
            float3 localCoord = float3(cloudX * (rho * rho), -0.02 * cloudY, cloudZ);

            density = blending * map5((localCoord + moving) * 100.0);
            color = 5.0 * lerp(float4(1.0, 0.9, 0.4, rho * density), float4(1.0, 0.3, 0.1, rho * density), rho);
        }
    }
}

float4 Radiance(Ray ray) {
    float4 sum = (float4)0;
    float marchingStep = lerp(0.27, 0.3, rnd());
    float marchingStart = 2.5;

    Ray currentRay;
    currentRay.origin = ray.origin + ray.dir * marchingStart;
    currentRay.dir = ray.dir;

    float transmittance = 1.0;

    for (int i = 0; i < 64 && transmittance > 1e-3; i++) {
        float3 p = currentRay.origin - gargantua.position_;

        float density;
        float4 ringColor;
        getCloudColorAndDensity(p, time * 0.1, ringColor, density);

        ringColor *= marchingStep;

        float tau = density * (1.0 - ringColor.w) * marchingStep;
        transmittance *= exp(-tau);

        sum += transmittance * density * ringColor;

#ifdef GRAVITATIONAL_LENSING
        float G_M1_M2 = 0.50;
        float d2 = dot(p, p);
        float3 gravityVec = normalize(-p) * (G_M1_M2 / d2);
        currentRay.dir = normalize(currentRay.dir + marchingStep * gravityVec);
#endif
        currentRay.origin = currentRay.origin + currentRay.dir * marchingStep;
    }

    float3 bgColor = getBgColor(currentRay.dir);
    sum = float4(bgColor * transmittance + sum.xyz, 1.0);

    return clamp(sum, 0.0, 1.0);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    seed = resolution.y * fragCoord.x / resolution.x + fragCoord.y / resolution.y;

    initScene();

    // No mouse — use default camera angle
    float2 screen_uv = float2(0.8, 0.4);

    // Gentle time-based camera drift
    float2 drift = float2(sin(time * 0.02) * 0.05, cos(time * 0.015) * 0.03);
    screen_uv += drift;

    float mouseSensitivity = 0.4;
    float3 cameraDir = sphericalToCartesian(1.0, -((HALF_PI - screen_uv.y * PI) * mouseSensitivity), (-screen_uv.x * TWO_PI) * mouseSensitivity);

    initCamera(gargantua.position_ + cameraDir * 8.0, gargantua.position_, float3(0.2, 1.0, 0.0), radians(50.0));

    float4 color = float4(0.0, 0.0, 0.0, 1.0);
    for (int i = 0; i < SPP; i++) {
        float2 screenCoord = fragCoord.xy + float2(rnd(), rnd());
        Ray ray = genRay(screenCoord);
        color += Radiance(ray);
    }

    float3 col = ((1.0 / (float)SPP) * color).rgb;

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(col.r, max(col.g, col.b));
    return float4(col * a, a);
}