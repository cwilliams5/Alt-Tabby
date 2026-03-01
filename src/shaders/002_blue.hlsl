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

float sdSphere(float3 pos, float size) {
    return length(pos) - size;
}

float sdBox(float3 pos, float3 size) {
    pos = abs(pos) - size;
    return max(max(pos.x, pos.y), pos.z);
}

float sdOctahedron(float3 p, float s) {
    p = abs(p);
    float m = p.x + p.y + p.z - s;
    float3 q;
    if (3.0 * p.x < m) q = p.xyz;
    else if (3.0 * p.y < m) q = p.yzx;
    else if (3.0 * p.z < m) q = p.zxy;
    else return m * 0.57735027;

    float k = clamp(0.5 * (q.z - q.y + s), 0.0, s);
    return length(float3(q.x, q.y - s + k, q.z - k));
}

float2x2 rot(float a) {
    float s = sin(a);
    float c = cos(a);
    return float2x2(c, s, -s, c);
}

float3 repeat(float3 pos, float3 span) {
    return abs(fmod(pos, span)) - span * 0.5;
}

float getDistance(float3 pos, float2 uv) {
    float3 originalPos = pos;

    for (int i = 0; i < 3; i++) {
        pos = abs(pos) - 4.5;
        pos.xz = mul(pos.xz, rot(1.0));
        pos.yz = mul(pos.yz, rot(1.0));
    }

    pos = repeat(pos, float3(4.0, 4.0, 4.0));

    float d0 = abs(originalPos.x) - 0.1;
    float d1 = sdBox(pos, float3(0.8, 0.8, 0.8));

    pos.xy = mul(pos.xy, rot(lerp(1.0, 2.0, abs(sin(time)))));
    float size = lerp(1.1, 1.3, abs(uv.y) * abs(uv.x));
    float d2 = sdSphere(pos, size);
    float dd2 = sdOctahedron(pos, 1.8);
    float ddd2 = lerp(d2, dd2, abs(sin(time)));

    return max(max(d1, -ddd2), -d0);
}

float4 PSMain(PSInput input) : SV_Target {
    float2 fragCoord = input.pos.xy;

    float2 p = (fragCoord.xy * 2.0 - resolution.xy) / min(resolution.x, resolution.y);

    // camera
    float3 cameraOrigin = float3(0.0, 0.0, -10.0 + time * 4.0);
    float3 cameraTarget = float3(cos(time) + sin(time / 2.0) * 10.0, exp(sin(time)) * 2.0, 3.0 + time * 4.0);
    float3 upDirection = float3(0.0, 1.0, 0.0);
    float3 cameraDir = normalize(cameraTarget - cameraOrigin);
    float3 cameraRight = normalize(cross(upDirection, cameraOrigin));
    float3 cameraUp = cross(cameraDir, cameraRight);
    float3 rayDirection = normalize(cameraRight * p.x + cameraUp * p.y + cameraDir);

    float depth = 0.0;
    float ac = 0.0;
    float3 rayPos = float3(0.0, 0.0, 0.0);
    float d = 0.0;

    for (int i = 0; i < 80; i++) {
        rayPos = cameraOrigin + rayDirection * depth;
        d = getDistance(rayPos, p);

        if (abs(d) < 0.0001) {
            break;
        }

        ac += exp(-d * lerp(5.0, 10.0, abs(sin(time))));
        depth += d;
    }

    float3 col = float3(0.0, 0.3, 0.7);
    ac *= 1.2 * (resolution.x / resolution.y - abs(p.x));
    float3 finalCol = col * ac * 0.06;

    // Post-processing
    float lum = dot(finalCol, float3(0.299, 0.587, 0.114));
    finalCol = lerp(finalCol, float3(lum, lum, lum), desaturate);
    finalCol = finalCol * (1.0 - darken);

    // Alpha from brightness, premultiplied
    float a = max(finalCol.r, max(finalCol.g, finalCol.b));
    return float4(finalCol * a, a);
}
