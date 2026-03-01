// Raindrops on Glass - Raindrop refraction overlay
// Original: Raindrops on glass by YeHaike (Shadertoy DdKyR1)
// License: All Rights Reserved (NonCommercial)
// iChannel0 replaced with procedural gradient; non-drop areas are transparent.

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

// --- Constants ---

#define RandomSeed 4.3315
#define NumberScaleOfStaticRaindrops 0.35
#define NumberScaleOfRollingRaindrops 0.35
#define RaindropBlur 0.0
#define BackgroundBlur 2.0
#define StaticRaindropUVScale 20.0
#define RollingRaindropUVScaleLayer01 2.25
#define RollingRaindropUVScaleLayer02 2.25

// --- 3D OpenSimplex2S noise with derivatives ---
// Output: float4(dF/dx, dF/dy, dF/dz, value)

float4 permute(float4 t) {
    return t * (t * 34.0 + 133.0);
}

// Gradient set is a normalized expanded rhombic dodecahedron
float3 grad(float hash) {
    // Random vertex of a cube, +/- 1 each
    float3 cube = fmod(floor(hash / float3(1.0, 2.0, 4.0)), 2.0) * 2.0 - 1.0;

    // Random edge of the three edges connected to that vertex
    float3 cuboct = cube;
    int idx = (int)(hash / 16.0);
    if (idx == 0) cuboct.x = 0.0;
    else if (idx == 1) cuboct.y = 0.0;
    else cuboct.z = 0.0;

    // Pick one of the four points on the rhombic face
    float tp = fmod(floor(hash / 8.0), 2.0);
    float3 rhomb = (1.0 - tp) * cube + tp * (cuboct + cross(cube, cuboct));

    // Expand so new edges match existing length
    float3 g = cuboct * 1.22474487139 + rhomb;
    g *= (1.0 - 0.042942436724648037 * tp) * 3.5946317686139184;
    return g;
}

// BCC lattice split into 2 cube lattices
float4 os2NoiseWithDerivativesPart(float3 X) {
    float3 b = floor(X);
    float4 i4 = float4(X - b, 2.5);

    float3 v1 = b + floor(dot(i4, (float4)0.25));
    float3 v2 = b + float3(1, 0, 0) + float3(-1, 1, 1) * floor(dot(i4, float4(-0.25, 0.25, 0.25, 0.35)));
    float3 v3 = b + float3(0, 1, 0) + float3(1, -1, 1) * floor(dot(i4, float4(0.25, -0.25, 0.25, 0.35)));
    float3 v4 = b + float3(0, 0, 1) + float3(1, 1, -1) * floor(dot(i4, float4(0.25, 0.25, -0.25, 0.35)));

    // Gradient hashes
    float4 hashes = permute(fmod(float4(v1.x, v2.x, v3.x, v4.x), 289.0));
    hashes = permute(fmod(hashes + float4(v1.y, v2.y, v3.y, v4.y), 289.0));
    hashes = fmod(permute(fmod(hashes + float4(v1.z, v2.z, v3.z, v4.z), 289.0)), 48.0);

    // Gradient extrapolations & kernel function
    float3 d1 = X - v1; float3 d2 = X - v2; float3 d3 = X - v3; float3 d4 = X - v4;
    float4 a = max(0.75 - float4(dot(d1, d1), dot(d2, d2), dot(d3, d3), dot(d4, d4)), 0.0);
    float4 aa = a * a; float4 aaaa = aa * aa;
    float3 g1 = grad(hashes.x); float3 g2 = grad(hashes.y);
    float3 g3 = grad(hashes.z); float3 g4 = grad(hashes.w);
    float4 extrapolations = float4(dot(d1, g1), dot(d2, g2), dot(d3, g3), dot(d4, g4));

    // Derivatives: -8.0 * mat4x3(d1,d2,d3,d4) * (aa*a*extrapolations) + mat4x3(g1,g2,g3,g4) * aaaa
    // mat4x3(col0,col1,col2,col3) * vec4(e) = col0*e.x + col1*e.y + col2*e.z + col3*e.w
    float4 aaa_ext = aa * a * extrapolations;
    float3 derivative = -8.0 * (d1 * aaa_ext.x + d2 * aaa_ext.y + d3 * aaa_ext.z + d4 * aaa_ext.w)
        + (g1 * aaaa.x + g2 * aaaa.y + g3 * aaaa.z + g4 * aaaa.w);

    return float4(derivative, dot(aaaa, extrapolations));
}

// Rotates domain, preserves shape
float4 os2NoiseWithDerivatives_Fallback(float3 X) {
    X = dot(X, (float3)(2.0 / 3.0)) - X;
    float4 result = os2NoiseWithDerivativesPart(X) + os2NoiseWithDerivativesPart(X + 144.5);
    return float4(dot(result.xyz, (float3)(2.0 / 3.0)) - result.xyz, result.w);
}

// Triangular XY alignment, Z moves up main diagonal
float4 os2NoiseWithDerivatives_ImproveXY(float3 X) {
    // Orthonormal map - GLSL column-major transposed for HLSL row-major mul(M, v)
    static const float3x3 orthonormalMap = float3x3(
         0.788675134594813, -0.211324865405187,  0.577350269189626,
        -0.211324865405187,  0.788675134594813,  0.577350269189626,
        -0.577350269189626, -0.577350269189626,  0.577350269189626);

    X = mul(orthonormalMap, X);
    float4 result = os2NoiseWithDerivativesPart(X) + os2NoiseWithDerivativesPart(X + 144.5);

    // result.xyz * orthonormalMap (GLSL row*mat = HLSL mul(v, M) with transposed matrix)
    // Since we already transposed for mul(M,v), mul(v, M) with same matrix = GLSL's v*M^T = v*original
    return float4(mul(result.xyz, orthonormalMap), result.w);
}

// --- Utility functions ---

float GradientWave(float b, float t) {
    return smoothstep(0.0, b, t) * smoothstep(1.0, b, t);
}

float Random(float2 UV, float Seed) {
    return frac(sin(dot(UV.xy * 13.235, float2(12.9898, 78.233)) * 0.000001) * 43758.5453123 * Seed);
}

float3 RandomVec3(float2 UV, float Seed) {
    return float3(Random(UV, Seed), Random(UV * 2.0, Seed), Random(UV * 3.0, Seed));
}

float4 RandomVec4(float2 UV, float Seed) {
    return float4(Random(UV * 1.5, Seed), Random(UV * 2.5, Seed), Random(UV * 3.5, Seed), Random(UV * 4.5, Seed));
}

// --- Raindrop surface ---
// Returns float3(height, dz/dx, dz/dy)

float3 RaindropSurface(float2 XY, float DistanceScale, float ZScale) {
    float A = DistanceScale;
    float x = XY.x;
    float y = XY.y;
    float N = 1.5;
    float M = 0.5;
    float S = ZScale;

    float TempZ = 1.0 - pow(x / A, 2.0) - pow(y / A, 2.0);
    float Z = pow(max(TempZ, 0.0), A / 2.0);
    float ZInMAndN = (Z - M) / (N - M);
    float t = min(max(ZInMAndN, 0.0), 1.0);

    float Height = S * t * t * (3.0 - 2.0 * t);

    float Part01 = S * (6.0 * t - 8.0 * t * t);
    float Part02 = 1.0 / (N - M);
    float Part03 = -1.0 / A * pow(max(TempZ, 0.0), A / 2.0 - 1.0);

    float Part03OfX = x * Part03;
    float Part03OfY = y * Part03;

    float TempValue = (ZInMAndN > 0.0 && ZInMAndN < 1.0) ? Part01 * Part02 : 0.0;

    float PartialDerivativeX = TempValue * Part03OfX;
    float PartialDerivativeY = TempValue * Part03OfY;
    float2 PartialDerivative = Height > 0.0 ? float2(PartialDerivativeX, PartialDerivativeY) : float2(0.0, 0.0);
    return float3(Height, PartialDerivative);
}

float MapToRange(float edge0, float edge1, float x) {
    return clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
}

float ProportionalMapToRange(float edge0, float edge1, float x) {
    return edge0 + (edge1 - edge0) * x;
}

// --- Static raindrops ---
// Returns float3(height, normal.xy)

float3 StaticRaindrops(float2 UV, float Time, float UVScale) {
    float2 TempUV = UV;
    TempUV *= UVScale;

    float2 ID = floor(TempUV);
    float3 RandVal = RandomVec3(float2(ID.x * 470.15, ID.y * 653.58), RandomSeed);
    TempUV = frac(TempUV) - 0.5;
    float2 RandomPoint = (RandVal.xy - 0.5) * 0.25;
    float2 XY = RandomPoint - TempUV;
    float Distance = length(TempUV - RandomPoint);

    float3 X = float3(float2(TempUV.x * 305.0 * 0.02, TempUV.y * 305.0 * 0.02), 1.8660254037844386);
    float4 noiseResult = os2NoiseWithDerivatives_ImproveXY(X);
    float EdgeRandomCurveAdjust = noiseResult.w * lerp(0.02, 0.175, frac(RandVal.x));

    Distance = EdgeRandomCurveAdjust * 0.5 + Distance;
    Distance = Distance * clamp(lerp(1.0, 55.0, RandomPoint.x), 1.0, 3.0);
    float Height = smoothstep(0.2, 0.0, Distance);

    float GradientFade = GradientWave(0.0005, frac(Time * 0.02 + RandVal.z));

    float DistanceMaxRange = 1.45 * GradientFade;
    float2 Direction = (TempUV - RandomPoint);

    float Theta = 3.141592653 - acos(dot(normalize(Direction), float2(0.0, 1.0)));
    Theta = Theta * RandVal.z;
    float DistanceScale = 0.2 / (1.0 - 0.8 * cos(Theta - 3.141593 / 2.0 - 1.6));
    float YDistance = length(float2(0.0, TempUV.y) - float2(0.0, RandomPoint.y));

    float NewDistance = MapToRange(0.0, DistanceMaxRange * pow(DistanceScale, 1.0), Distance);

    float Scale = 1.65 * (0.2 + DistanceScale * 1.0) * DistanceMaxRange * lerp(1.5, 0.5, RandVal.x);
    float2 TempXY = float2(XY.x * 1.0, XY.y) * 4.0;
    float RandomScale = ProportionalMapToRange(0.85, 1.35, RandVal.z);
    TempXY.x = RandomScale * lerp(TempXY.x, TempXY.x / smoothstep(1.0, 0.4, YDistance * RandVal.z), smoothstep(1.0, 0.0, RandVal.x));
    TempXY = TempXY + EdgeRandomCurveAdjust * 1.0;
    float3 HeightAndNormal = RaindropSurface(TempXY, Scale, 1.0);
    HeightAndNormal.yz = -HeightAndNormal.yz;

    float RandomVisible = (frac(RandVal.z * 10.0 * RandomSeed) < NumberScaleOfStaticRaindrops ? 1.0 : 0.0);
    HeightAndNormal.yz = HeightAndNormal.yz * RandomVisible;
    HeightAndNormal.x = smoothstep(0.0, 1.0, HeightAndNormal.x) * RandomVisible;

    return HeightAndNormal;
}

// --- Rolling raindrops ---
// Returns float4(height, normal.xy, trail)

float4 RollingRaindrops(float2 UV, float Time, float UVScale) {
    float2 LocalUV = UV * UVScale;
    float2 TempUV = LocalUV;

    float2 ConstantA = float2(6.0, 1.0);
    float2 GridNum = ConstantA * 2.0;
    float2 GridID = floor(LocalUV * GridNum);

    float RandomFloat = Random(float2(GridID.x * 131.26, GridID.x * 101.81), RandomSeed);

    float TimeMovingY = Time * 0.85 * ProportionalMapToRange(0.1, 0.25, RandomFloat);
    LocalUV.y += TimeMovingY;
    float YShift = RandomFloat;
    LocalUV.y += YShift;

    float2 ScaledUV = LocalUV * GridNum;
    GridID = floor(ScaledUV);
    float3 RandVec3 = RandomVec3(float2(GridID.x * 17.32, GridID.y * 2217.54), RandomSeed);

    float2 GridUV = frac(ScaledUV) - float2(0.5, 0.0);

    float SwingX = RandVec3.x - 0.5;

    float SwingY = TempUV.y * 20.0;
    float SwingPosition = sin(SwingY + sin(GridID.y * RandVec3.z + SwingY) + GridID.y * RandVec3.z);
    SwingX += SwingPosition * (0.5 - abs(SwingX)) * (RandVec3.z - 0.5);
    SwingX *= 0.65;
    float RandomNormalizedTime = frac(TimeMovingY + RandVec3.z) * 1.0;
    SwingY = (GradientWave(0.87, RandomNormalizedTime) - 0.5) * 0.9 + 0.5;
    SwingY = clamp(SwingY, 0.15, 0.85);
    float2 Position = float2(SwingX, SwingY);

    float2 XY = Position - GridUV;
    float2 Direction = (GridUV - Position) * ConstantA.yx;
    float Distance = length(Direction);

    float3 X = float3(float2(TempUV.x * 513.20 * 0.02, TempUV.y * 779.40 * 0.02), 2.1660251037743386);
    float4 NoiseResult = os2NoiseWithDerivatives_ImproveXY(X);
    float EdgeRandomCurveAdjust = NoiseResult.w * lerp(0.02, 0.175, frac(RandVec3.y));

    Distance = EdgeRandomCurveAdjust + Distance;
    float Height = smoothstep(0.2, 0.0, Distance);
    float NewDistance = MapToRange(0.0, 0.2, Distance);

    float DistanceMaxRange = 1.45;

    float Theta = 3.141592653 - acos(dot(normalize(Direction), float2(0.0, 1.0)));
    Theta = Theta * RandVec3.z;
    float DistanceScale = 0.2 / (1.0 - 0.8 * cos(Theta - 3.141593 / 2.0 - 1.6));
    float Scale = 1.65 * (0.2 + DistanceScale * 1.0) * DistanceMaxRange * lerp(1.0, 0.25, RandVec3.x * 1.0);
    float2 TempXY = float2(XY.x * 1.0, XY.y) * 4.0;
    float RandomScale = ProportionalMapToRange(0.85, 1.35, RandVec3.z);
    TempXY = TempXY * float2(1.0, 4.2) + EdgeRandomCurveAdjust * 0.85;
    float3 HeightAndNormal = RaindropSurface(TempXY, Scale, 1.0);

    // Trail
    float TrailY = pow(smoothstep(1.0, SwingY, GridUV.y), 0.5);
    float TrailX = abs(GridUV.x - SwingX) * lerp(0.8, 4.0, smoothstep(0.0, 1.0, RandVec3.x));
    float Trail = smoothstep(0.25 * TrailY, 0.15 * TrailY * TrailY, TrailX);
    float TrailClamp = smoothstep(-0.02, 0.02, GridUV.y - SwingY);
    Trail *= TrailClamp * TrailY;

    float SignOfTrailX = sign(GridUV.x - SwingX);
    float3 NoiseInput = float3(float2(TempUV.x * 513.20 * 0.02 * SignOfTrailX, TempUV.y * 779.40 * 0.02), 2.1660251037743386);
    float4 TrailNoiseResult = os2NoiseWithDerivatives_ImproveXY(NoiseInput);
    float TrailEdgeRandomCurveAdjust = TrailNoiseResult.w * lerp(0.002, 0.175, frac(RandVec3.y));
    float TrailXDistance = MapToRange(0.0, 0.1, TrailEdgeRandomCurveAdjust * 0.5 + TrailX);
    float2 TrailDirection = SignOfTrailX * float2(1.0, 0.0) + float2(0.0, 1.0) * smoothstep(1.0, 0.0, Trail) * 0.5;
    float2 TrailXY = TrailDirection * 1.0 * TrailXDistance;

    float3 TrailHeightAndNormal = RaindropSurface(TrailXY, 1.0, 1.0);

    TrailHeightAndNormal = TrailHeightAndNormal * pow(Trail * RandVec3.y, 2.0);
    TrailHeightAndNormal.x = smoothstep(0.0, 1.0, TrailHeightAndNormal.x);

    // Remain trail droplets
    SwingY = TempUV.y;
    float RemainTrail = smoothstep(0.2 * TrailY, 0.0, TrailX);
    float RemainDroplet = max(0.0, (sin(SwingY * (1.0 - SwingY) * 120.0) - GridUV.y)) * RemainTrail * TrailClamp * RandVec3.z;
    SwingY = frac(SwingY * 10.0) + (GridUV.y - 0.5);
    float2 RemainDropletXY = GridUV - float2(SwingX, SwingY);
    RemainDropletXY = RemainDropletXY * float2(1.2, 0.8);

    RemainDropletXY = RemainDropletXY + EdgeRandomCurveAdjust * 0.85;
    float3 RemainDropletHeightAndNormal = RaindropSurface(RemainDropletXY, 2.0 * RemainDroplet, 1.0);

    RemainDropletHeightAndNormal.x = smoothstep(0.0, 1.0, RemainDropletHeightAndNormal.x);
    RemainDropletHeightAndNormal = TrailHeightAndNormal.x > 0.0 ? (float3)0 : RemainDropletHeightAndNormal;

    float4 ReturnValue;
    ReturnValue.x = HeightAndNormal.x + TrailHeightAndNormal.x * TrailY * TrailClamp + RemainDropletHeightAndNormal.x * TrailY * TrailClamp;
    ReturnValue.yz = HeightAndNormal.yz + TrailHeightAndNormal.yz + RemainDropletHeightAndNormal.yz;
    ReturnValue.w = Trail;

    float RandomVisible = (frac(RandVec3.z * 20.0 * RandomSeed) < NumberScaleOfRollingRaindrops ? 1.0 : 0.0);
    ReturnValue = ReturnValue * RandomVisible;
    return ReturnValue;
}

// --- Combined raindrops ---

float4 Raindrops(float2 UV, float Time, float UVScale00, float UVScale01, float UVScale02) {
    float3 StaticRaindrop = StaticRaindrops(UV, Time, UVScale00);
    float4 RollingRaindrop01 = RollingRaindrops(UV, Time, UVScale01);

    float Height = StaticRaindrop.x + RollingRaindrop01.x;
    float2 Normal = StaticRaindrop.yz + RollingRaindrop01.yz;
    float Trail = RollingRaindrop01.w;

    return float4(Height, Normal, Trail);
}

// --- Procedural backdrop (replaces iChannel0 texture) ---
// Simple gradient so raindrop refraction has something to distort.

float3 ProceduralBackdrop(float2 uv, float blur) {
    // Subtle cool-toned gradient: darker at top, lighter at bottom
    float3 topColor = float3(0.08, 0.10, 0.14);
    float3 botColor = float3(0.18, 0.22, 0.28);
    float3 base = lerp(topColor, botColor, uv.y);

    // Add slight horizontal variation
    base += 0.02 * sin(uv.x * 6.28318 + 0.5);

    // Blur softens contrast (simulate textureLod mip level)
    float blurFade = saturate(blur * 0.15);
    float3 avg = (topColor + botColor) * 0.5;
    base = lerp(base, avg, blurFade);

    return base;
}

// --- Entry point ---

float4 PSMain(PSInput input) : SV_Target {
    // Flip Y to match Shadertoy convention (Y=0 at bottom) so rain falls downward
    float2 fragCoord = float2(input.pos.x, resolution.y - input.pos.y);

    float Time = time;
    float ScaledTime = Time * 0.2;
    float2 GlobalUV = fragCoord.xy / resolution.xy;
    float2 LocalUV = (fragCoord.xy - 0.5 * resolution.xy) / resolution.y;

    float RaindropsAmount = sin(Time * 0.25) * 0.5 + 0.5;

    float MaxBlur = lerp(BackgroundBlur, BackgroundBlur * 2.0, RaindropsAmount);
    float MinBlur = RaindropBlur;

    float StaticRaindropsAmount = smoothstep(-0.5, 1.0, RaindropsAmount) * 2.0;
    float RollingRaindropsAmount01 = smoothstep(0.25, 0.75, RaindropsAmount);
    float RollingRaindropsAmount02 = smoothstep(0.0, 0.5, RaindropsAmount);

    float4 Raindrop = Raindrops(LocalUV, Time,
        StaticRaindropUVScale, RollingRaindropUVScaleLayer01, RollingRaindropUVScaleLayer02);

    float RaindropHeight = Raindrop.x;
    float RaindropTrail = Raindrop.w;
    float2 RaindropNormal = -Raindrop.yz;
    RaindropNormal = RaindropHeight > 0.0 ? RaindropNormal * 0.15 : float2(0.0, 0.0);

    float2 UVWithNormal = GlobalUV + RaindropNormal;
    float EdgeColorScale = smoothstep(0.2, 0.0, length(RaindropNormal));
    EdgeColorScale = RaindropHeight > 0.0 ? pow(EdgeColorScale, 0.5) * 0.2 + 0.8 : 1.0;

    float Blur = lerp(MinBlur, MaxBlur, smoothstep(0.0, 1.6, length(RaindropNormal)));
    Blur = RaindropHeight > 0.0 ? Blur : MaxBlur;
    Blur = ProportionalMapToRange(MinBlur, Blur, 1.0 - RaindropTrail);
    EdgeColorScale = pow(EdgeColorScale, 0.85);

    float3 FinalColor = ProceduralBackdrop(UVWithNormal, Blur) * EdgeColorScale;

    // Darken / desaturate post-processing
    float lum = dot(FinalColor, float3(0.299, 0.587, 0.114));
    FinalColor = lerp(FinalColor, float3(lum, lum, lum), desaturate);
    FinalColor = FinalColor * (1.0 - darken);

    // Transparency: raindrop areas visible, non-drop areas transparent
    // so the underlying acrylic/mica backdrop shows through
    float dropMask = saturate(RaindropHeight + RaindropTrail * 0.3);
    float alpha = dropMask;

    // Premultiplied alpha
    return float4(FinalColor * alpha, alpha);
}
