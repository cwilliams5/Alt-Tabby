// Tentacles of Light - iMac screensaver inspired
// Original: https://www.shadertoy.com/view/WsyfRh by oneshade

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

float Hash11(float x) {
    return frac(sin(x * 1254.5763) * 57465.57);
}

float3 hue2rgb(float hue) {
    hue *= 6.0;
    float x = 1.0 - abs(fmod(hue, 2.0) - 1.0);

    float3 rgb = float3(1.0, x, 0.0);
    if (hue < 2.0 && hue >= 1.0) {
        rgb = float3(x, 1.0, 0.0);
    }

    if (hue < 3.0 && hue >= 2.0) {
        rgb = float3(0.0, 1.0, x);
    }

    if (hue < 4.0 && hue >= 3.0) {
        rgb = float3(0.0, x, 1.0);
    }

    if (hue < 5.0 && hue >= 4.0) {
        rgb = float3(x, 0.0, 1.0);
    }

    if (hue < 6.0 && hue >= 5.0) {
        rgb = float3(1.0, 0.0, x);
    }

    return rgb;
}

float lineDist(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;
    float2 uv = (fragCoord - 0.5 * resolution.xy) / resolution.y;
    float3 color = (float3)0.0;

    float t = time * 0.25;
    float c = cos(t), s = sin(t);
    uv -= float2(cos(t), sin(t)) * 0.15;

    for (float tentacleID = 0.0; tentacleID < 8.0; tentacleID++) {
        float distFromOrigin = length(uv);
        float tentacleHash = Hash11(tentacleID + 1.0);
        float angle = tentacleID / 4.0 * 3.14 + time * (tentacleHash - 0.5);

        float3 tentacleColor = hue2rgb(frac(0.5 * (distFromOrigin - 0.1 * time)));
        float fadeOut = 1.0 - pow(distFromOrigin, sin(tentacleHash * time) + 1.5);

        float2 offsetVector = uv.yx * float2(-1.0, 1.0);
        float2 offset = offsetVector * sin(tentacleHash * (distFromOrigin + tentacleHash * time)) * (1.0 - distFromOrigin);

        color += smoothstep(0.03, 0.0, lineDist(uv + offset, float2(0.0, 0.0), float2(cos(angle), sin(angle)) * 1000.0)) * fadeOut * tentacleColor;
    }

    // Darken/desaturate post-processing
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
