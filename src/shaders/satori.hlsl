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

static float k = 20.0;
static float field = 0.0;
static float2 g_fragCoord;

// Time-based sweep replacing iMouse for color palette and circle position
static float2 fakeMouse;

float2 centerPos(float2 border, float2 offset, float2 vel) {
    float2 c;
    if (vel.x == 0.0 && vel.y == 0.0) {
        c = fakeMouse * resolution;
    } else {
        c = offset + vel * time * 0.5;
        c = fmod(c, 2.0 - 4.0 * border);
        c = abs(c);
        if (c.x > 1.0 - border.x) c.x = 2.0 - c.x - 2.0 * border.x;
        if (c.x < border.x) c.x = 2.0 * border.x - c.x;
        if (c.y > 1.0 - border.y) c.y = 2.0 - c.y - 2.0 * border.y;
        if (c.y < border.y) c.y = 2.0 * border.y - c.y;
    }
    return c;
}

void circle(float r, float3 col, float2 offset, float2 vel) {
    float2 pos = g_fragCoord.xy / resolution.y;
    float aspect = resolution.x / resolution.y;
    float2 c = centerPos(float2(r / aspect, r), offset, vel);
    c.x *= aspect;
    float d = distance(pos, c);
    field += (k * r) / (d * d);
}

float3 band(float shade, float low, float high, float3 col1, float3 col2) {
    if ((shade >= low) && (shade <= high)) {
        float delta = (shade - low) / (high - low);
        float3 colDiff = col2 - col1;
        return col1 + (delta * colDiff);
    } else {
        return float3(0.0, 0.0, 0.0);
    }
}

float3 gradient(float shade) {
    float3 colour = float3((sin(time / 2.0) * 0.25) + 0.25, 0.0, (cos(time / 2.0) * 0.25) + 0.25);

    float2 mouseScaled = fakeMouse;
    float3 col1 = float3(mouseScaled.x, 0.0, 1.0 - mouseScaled.x);
    float3 col2 = float3(1.0 - mouseScaled.x, 0.0, mouseScaled.x);
    float3 col3 = float3(mouseScaled.y, 1.0 - mouseScaled.y, mouseScaled.y);
    float3 col4 = float3((mouseScaled.x + mouseScaled.y) / 2.0, (mouseScaled.x + mouseScaled.y) / 2.0,
                         1.0 - (mouseScaled.x + mouseScaled.y) / 2.0);
    float3 col5 = float3(mouseScaled.y, mouseScaled.y, mouseScaled.y);

    colour += band(shade, 0.0, 0.3, colour, col1);
    colour += band(shade, 0.3, 0.6, col1, col2);
    colour += band(shade, 0.6, 0.8, col2, col3);
    colour += band(shade, 0.8, 0.9, col3, col4);
    colour += band(shade, 0.9, 1.0, col4, col5);

    return colour;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    g_fragCoord = fragCoord;
    field = 0.0;
    fakeMouse = float2(sin(time * 0.05) * 0.5 + 0.5, cos(time * 0.07) * 0.5 + 0.5);

    circle(0.03, float3(0.7, 0.2, 0.8), (float2)0.6, float2(0.30, 0.70));
    circle(0.05, float3(0.7, 0.9, 0.6), (float2)0.1, float2(0.02, 0.20));
    circle(0.07, float3(0.3, 0.4, 0.1), (float2)0.1, float2(0.10, 0.04));
    circle(0.10, float3(0.2, 0.5, 0.1), (float2)0.3, float2(0.10, 0.20));
    circle(0.20, float3(0.1, 0.3, 0.7), (float2)0.2, float2(0.40, 0.25));
    circle(0.30, float3(0.9, 0.4, 0.2), (float2)0.0, float2(0.15, 0.20));
    circle(0.30, float3(0.0, 0.0, 0.0), (float2)0.0, float2(0.0, 0.0));

    float shade = min(1.0, max(field / 256.0, 0.0));

    float3 color = gradient(shade);

    // Post-processing: darken/desaturate
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
