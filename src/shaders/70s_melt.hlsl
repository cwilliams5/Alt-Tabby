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

float cosRange(float amt, float range, float minimum) {
    return (((1.0 + cos(radians(amt))) * 0.5) * range) + minimum;
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    static const int zoom = 40;
    static const float brightness = 0.975;
    float t = time * 1.25;
    float2 uv = fragCoord.xy / resolution.xy;
    float2 p = (2.0 * fragCoord.xy - resolution.xy) / max(resolution.x, resolution.y);
    float ct = cosRange(t * 5.0, 3.0, 1.1);
    float xBoost = cosRange(t * 0.2, 5.0, 5.0);
    float yBoost = cosRange(t * 0.1, 10.0, 5.0);
    float fScale = cosRange(t * 15.5, 1.25, 0.5);

    for (int i = 1; i < zoom; i++) {
        float fi = float(i);
        float2 newp = p;
        newp.x += 0.25 / fi * sin(fi * p.y + t * cos(ct) * 0.5 / 20.0 + 0.005 * fi) * fScale + xBoost;
        newp.y += 0.25 / fi * sin(fi * p.x + t * ct * 0.3 / 40.0 + 0.03 * float(i + 15)) * fScale + yBoost;
        p = newp;
    }

    float3 col = float3(0.5 * sin(3.0 * p.x) + 0.5, 0.5 * sin(3.0 * p.y) + 0.5, sin(p.x + p.y));
    col *= brightness;

    // Vignette border
    float vigAmt = 5.0;
    float vignette = (1.0 - vigAmt * (uv.y - 0.5) * (uv.y - 0.5)) * (1.0 - vigAmt * (uv.x - 0.5) * (uv.x - 0.5));
    float extrusion = (col.x + col.y + col.z) / 4.0;
    extrusion *= 1.5;
    extrusion *= vignette;

    // Darken/desaturate post-processing
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = lerp(col, float3(lum, lum, lum), desaturate);
    col = col * (1.0 - darken);

    // Alpha from original extrusion, premultiply
    float a = saturate(extrusion);
    return float4(col * a, a);
}
