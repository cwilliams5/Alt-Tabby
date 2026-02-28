// Jasz Universe - Volumetric nebula fog with camera movement
// Original: Shadertoy by Jan Mroz (jaszunio15)
// License: CC BY 3.0
// Audio reactivity stripped; replaced with time-based pulse.

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

// --- Constants (from Shadertoy Common tab, non-HQ branch) ---
static const float NOISE_ALPHA_MULTIPLIER = 0.5;
static const float NOISE_SIZE_MULTIPLIER  = 1.8;
static const int   RAYS_COUNT             = 54;
static const float STEP_MODIFIER          = 1.0175;
static const float SHARPNESS              = 0.02;
static const float NOISE_LAYERS_COUNT     = 4.0;
static const float JITTERING              = 0.08;
static const float DITHER                 = 0.3;
static const float NEAR_PLANE             = 0.6;
static const float RENDER_DISTANCE        = 2.0;
static const float BRIGHTNESS             = 5.0;
static const float3 COLOR1                = float3(0.0, 1.0, 1.0);
static const float3 COLOR2                = float3(1.0, 0.0, 0.9);
static const float CAMERA_SPEED           = 0.04;
static const float CAMERA_ROTATION_SPEED  = 0.06;

// --- Helper functions ---

float hash(float3 v) {
    return frac(sin(dot(v, float3(11.51721, 67.12511, 9.7561))) * 1551.4172);
}

float getNoiseFromVec3(float3 v) {
    float3 rootV = floor(v);
    float3 f = smoothstep(0.0, 1.0, frac(v));

    float n000 = hash(rootV);
    float n001 = hash(rootV + float3(0, 0, 1));
    float n010 = hash(rootV + float3(0, 1, 0));
    float n011 = hash(rootV + float3(0, 1, 1));
    float n100 = hash(rootV + float3(1, 0, 0));
    float n101 = hash(rootV + float3(1, 0, 1));
    float n110 = hash(rootV + float3(1, 1, 0));
    float n111 = hash(rootV + float3(1, 1, 1));

    float4 n = lerp(float4(n000, n010, n100, n110), float4(n001, n011, n101, n111), f.z);
    n.xy = lerp(float2(n.x, n.z), float2(n.y, n.w), f.y);
    return lerp(n.x, n.y, f.x);
}

float volumetricFog(float3 v, float noiseMod) {
    float noise = 0.0;
    float alpha = 1.0;
    float3 pt = v;
    for (float i = 0.0; i < NOISE_LAYERS_COUNT; i++) {
        noise += getNoiseFromVec3(pt) * alpha;
        pt *= NOISE_SIZE_MULTIPLIER;
        alpha *= NOISE_ALPHA_MULTIPLIER;
    }

    noise *= 0.575;

    // MUTATE_SHAPE enabled: animate fog edge over time
    float edge = 0.1 + getNoiseFromVec3(v * 0.5 + float3(time * 0.03, time * 0.03, time * 0.03)) * 0.8;

    noise = (0.5 - abs(edge * (1.0 + noiseMod * 0.05) - noise)) * 2.0;
    return (smoothstep(1.0 - SHARPNESS * 2.0, 1.0 - SHARPNESS, noise * noise)
          + (1.0 - smoothstep(1.3, 0.6, noise))) * 0.2;
}

float3 nearPlanePoint(float2 v, float t) {
    return float3(v.x, NEAR_PLANE * (1.0 + sin(t * 0.2) * 0.4), v.y);
}

float3 fogMarch(float3 rayStart, float3 rayDirection, float t, float disMod) {
    float stepLen = RENDER_DISTANCE / (float)RAYS_COUNT;
    float3 fog = float3(0.0, 0.0, 0.0);
    float3 pt = rayStart;

    for (int i = 0; i < RAYS_COUNT; i++) {
        pt += rayDirection * stepLen;
        fog += volumetricFog(pt, disMod)
             * lerp(COLOR1, COLOR2 * (1.0 + disMod * 0.5),
                    getNoiseFromVec3((pt + float3(12.51, 52.167, 1.146)) * 0.5))
             * lerp(1.0, getNoiseFromVec3(pt * 40.0) * 2.0, DITHER)
             * getNoiseFromVec3(pt * 0.2 + 20.0) * 2.0;

        stepLen *= STEP_MODIFIER;
    }

    fog = (fog / (float)RAYS_COUNT)
        * (pow(getNoiseFromVec3(rayStart + rayDirection * RENDER_DISTANCE), 2.0) * 3.0
           + disMod * 0.5);

    return fog;
}

// Audio stripped - gentle time-based pulse as substitute
float getBeat() {
    return smoothstep(0.6, 0.9, pow(sin(time * 1.5) * 0.5 + 0.5, 4.0)) * 0.3;
}

// --- Entry point ---

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float musicVolume = getBeat();
    float2 res = resolution;
    float2 uv = (2.0 * fragCoord - res) / res.x;

    // Camera movement
    float3 cameraCenter = float3(
        sin(time * CAMERA_SPEED) * 10.0,
        time * CAMERA_SPEED * 10.0,
        cos(time * 0.78 * CAMERA_SPEED + 2.14) * 10.0);

    // Rotation matrix (GLSL column-major -> HLSL row-major transposed)
    float angleY = sin(time * CAMERA_ROTATION_SPEED * 2.0);
    float angleX = cos(time * 0.712 * CAMERA_ROTATION_SPEED);
    float angleZ = sin(time * 1.779 * CAMERA_ROTATION_SPEED);

    float3x3 rotX = float3x3(
        1, 0,            0,
        0, sin(angleX), -cos(angleX),
        0, cos(angleX),  sin(angleX));

    float3x3 rotZ = float3x3(
        sin(angleZ), -cos(angleZ), 0,
        cos(angleZ),  sin(angleZ), 0,
        0,            0,           1);

    float3x3 rotY = float3x3(
        sin(angleY),  0, -cos(angleY),
        0,            1,  0,
        cos(angleY),  0,  sin(angleY));

    float3x3 rotation = mul(rotX, mul(rotZ, rotY));

    float3 rayDirection = mul(rotation, normalize(nearPlanePoint(uv, time)));
    float3 rayStart = rayDirection * 0.2 + cameraCenter;

    // Jittering
    rayStart += rayDirection * (hash(float3(uv + 4.0, frac(time) + 2.0)) - 0.5) * JITTERING;

    float3 fog = fogMarch(rayStart, rayDirection, time, musicVolume);

    // Postprocess
    fog *= 2.5 * BRIGHTNESS;
    fog += 0.07 * lerp(COLOR1, COLOR2, 0.5);
    fog = sqrt(smoothstep(0.0, 1.5, fog));

    float3 color = fog * smoothstep(0.0, 10.0, time);

    // Darken / desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
