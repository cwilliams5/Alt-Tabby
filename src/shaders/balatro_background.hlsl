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

#define MID_FLASH 0.0
#define VORT_SPEED 0.8
#define VORT_OFFSET 0.0
#define PIXEL_SIZE_FAC 700.0

static const float4 BLUE  = float4(pow(float3(0.0, 157.0/255.0, 255.0/255.0), (float3)2.2), 1.0);
static const float4 RED   = float4(pow(float3(254.0/255.0, 95.0/255.0, 85.0/255.0), (float3)2.2), 1.0);
static const float4 BLACK = float4(pow(0.6 * float3(79.0/255.0, 99.0/255.0, 103.0/255.0), (float3)2.2), 1.0);

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float res_len = length(resolution.xy);

    // Convert to UV coords and floor for pixel effect
    float pixel_size = res_len / PIXEL_SIZE_FAC;
    float2 uv = (floor(fragCoord.xy * (1.0 / pixel_size)) * pixel_size - 0.5 * resolution.xy) / res_len;
    float uv_len = length(uv);

    // Adding in a center swirl, changes with time
    float speed = time * VORT_SPEED;
    float clamped_speed = min(6.0, speed);
    float new_pixel_angle = atan2(uv.y, uv.x) + (2.2 + 0.4 * clamped_speed) * uv_len - 1.0 - speed * 0.05 - clamped_speed * speed * 0.02 + VORT_OFFSET;
    float2 mid = normalize(resolution.xy) * 0.5;
    float2 sv = float2(uv_len * cos(new_pixel_angle) + mid.x, uv_len * sin(new_pixel_angle) + mid.y) - mid;

    // Now add the smoke effect to the swirled UV
    sv *= 30.0;
    speed = time * 6.0 * VORT_SPEED + VORT_OFFSET + 1033.0;
    float2 uv2 = float2(sv.x + sv.y, sv.x + sv.y);

    [unroll]
    for (int i = 0; i < 5; i++) {
        uv2 += sin(max(sv.x, sv.y)) + sv;
        sv  += 0.5 * float2(cos(5.1123314 + 0.353 * uv2.y + speed * 0.131121), sin(uv2.x - 0.113 * speed));
        sv  -= cos(sv.x + sv.y) - sin(sv.x * 0.711 - sv.y);
    }

    // Make the smoke amount range from 0 - 2
    float smoke_res = min(2.0, max(-2.0, 1.5 + length(sv) * 0.12 - 0.17 * min(10.0, time * 1.2 - 4.0)));
    float smoke_adj = (smoke_res - 0.2) * 0.6 + 0.2;
    smoke_res = lerp(smoke_adj, smoke_res, step(0.2, smoke_res));

    float c1p = max(0.0, 1.0 - 2.0 * abs(1.0 - smoke_res));
    float c2p = max(0.0, 1.0 - 2.0 * smoke_res);
    float cb = 1.0 - min(1.0, c1p + c2p);
    float4 ret_col = RED * c1p + BLUE * c2p + float4(cb * BLACK.rgb, cb * RED.a);
    float max_cp = max(c1p, c2p);
    float mod_flash = max(MID_FLASH * 0.8, max_cp * 5.0 - 4.4) + MID_FLASH * max_cp;
    float4 final_col = ret_col * (1.0 - mod_flash) + mod_flash;
    float3 color = pow(final_col.rgb, (float3)(1.0 / 2.2));

    // Desaturate and darken
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(color, float3(lum, lum, lum), desaturate);
    color = color * (1.0 - darken);

    // Alpha from brightness, premultiply
    float a = max(color.r, max(color.g, color.b));
    return float4(color * a, a);
}
