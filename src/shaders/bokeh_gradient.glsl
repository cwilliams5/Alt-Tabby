const float animationProgress = 1.0; // 애니메이션 진행도
const float bloomIntensity = 2.1; // 블룸 강도
const float baseCircleSize = 0.3; // 기본 원 크기
const vec3 primaryColor = vec3(0.2, 0.2, 0.9); // 주요 컬러 (청록)
const vec3 secondaryColor = vec3(0.8, 0.4, 0.9); // 보조 컬러 (보라)
const vec3 accentColor = vec3(0.4, 0.9, 0.6); // 강조 컬러 (연두)

const float overlayAlpha = 0.5; // 전체 오버레이 알파값
const float circleOpacity = 0.4; // 원형 패턴 투명도
const float softness = 0.2; // 원 가장자리 부드러움
const float moveSpeed = 0.6; // 원들의 움직임 속도
const float sizeVariation = 0.5; // 크기 변화 정도

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    // Y 방향 반전
    vec2 flippedCoord = vec2(fragCoord.x, iResolution.y - fragCoord.y);
    vec2 uv = flippedCoord / iResolution.xy;

    // 투명한 배경
    vec4 baseColor = vec4(0.0, 0.0, 0.0, 0.0);

    // 애니메이션에 따른 효과 강도
    float effectStrength = smoothstep(0.0, 1.0, animationProgress);

    // 시간 기반 변수들
    float time = iTime * moveSpeed;

    // 8개 원의 고정 위치와 개별 움직임
    // 원 1
    vec2 pos1 = vec2(0.3, 0.4) + vec2(sin(time) * 0.08, cos(time * 1.2) * 0.06) * effectStrength;
    float radius1 = baseCircleSize * (1.2 + sin(time * 2.1) * sizeVariation) * effectStrength;
    float dist1 = distance(uv, pos1);
    float circle1 = 1.0 - smoothstep(radius1 - softness, radius1 + softness, dist1);

    // 원 2
    vec2 pos2 = vec2(0.7, 0.6) + vec2(cos(time + 1.0) * 0.07, sin(time * 0.8 + 2.0) * 0.09) * effectStrength;
    float radius2 = baseCircleSize * (0.9 + cos(time * 1.8 + 1.5) * sizeVariation) * effectStrength;
    float dist2 = distance(uv, pos2);
    float circle2 = 1.0 - smoothstep(radius2 - softness, radius2 + softness, dist2);

    // 원 3
    vec2 pos3 = vec2(0.5, 0.3) + vec2(sin(time * 1.3 + 3.0) * 0.06, cos(time + 4.0) * 0.08) * effectStrength;
    float radius3 = baseCircleSize * (1.1 + sin(time * 2.5 + 2.0) * sizeVariation) * effectStrength;
    float dist3 = distance(uv, pos3);
    float circle3 = 1.0 - smoothstep(radius3 - softness, radius3 + softness, dist3);

    // 원 4
    vec2 pos4 = vec2(0.2, 0.7) + vec2(cos(time * 0.9 + 5.0) * 0.09, sin(time * 1.1 + 1.0) * 0.05) * effectStrength;
    float radius4 = baseCircleSize * (1.0 + cos(time * 1.9 + 3.5) * sizeVariation) * effectStrength;
    float dist4 = distance(uv, pos4);
    float circle4 = 1.0 - smoothstep(radius4 - softness, radius4 + softness, dist4);

    // 원 5
    vec2 pos5 = vec2(0.8, 0.2) + vec2(sin(time * 1.4 + 2.5) * 0.07, cos(time * 0.7 + 3.5) * 0.06) * effectStrength;
    float radius5 = baseCircleSize * (0.8 + sin(time * 2.2 + 4.0) * sizeVariation) * effectStrength;
    float dist5 = distance(uv, pos5);
    float circle5 = 1.0 - smoothstep(radius5 - softness, radius5 + softness, dist5);

    // 원 6
    vec2 pos6 = vec2(0.6, 0.8) + vec2(cos(time * 1.6 + 4.5) * 0.08, sin(time * 0.6 + 2.5) * 0.07) * effectStrength;
    float radius6 = baseCircleSize * (1.3 + cos(time * 1.7 + 5.0) * sizeVariation) * effectStrength;
    float dist6 = distance(uv, pos6);
    float circle6 = 1.0 - smoothstep(radius6 - softness, radius6 + softness, dist6);

    // 원 7
    vec2 pos7 = vec2(0.4, 0.6) + vec2(sin(time * 0.8 + 6.0) * 0.05, cos(time * 1.5 + 1.5) * 0.09) * effectStrength;
    float radius7 = baseCircleSize * (1.1 + sin(time * 2.8 + 1.0) * sizeVariation) * effectStrength;
    float dist7 = distance(uv, pos7);
    float circle7 = 1.0 - smoothstep(radius7 - softness, radius7 + softness, dist7);

    // 원 8
    vec2 pos8 = vec2(0.1, 0.5) + vec2(cos(time * 1.2 + 3.5) * 0.06, sin(time * 0.9 + 4.5) * 0.08) * effectStrength;
    float radius8 = baseCircleSize * (0.9 + cos(time * 2.0 + 2.5) * sizeVariation) * effectStrength;
    float dist8 = distance(uv, pos8);
    float circle8 = 1.0 - smoothstep(radius8 - softness, radius8 + softness, dist8);

    // 각 원의 색상 오버레이
    vec3 overlay1 = primaryColor * circle1 * circleOpacity;
    vec3 overlay2 = secondaryColor * circle2 * circleOpacity * 0.9;
    vec3 overlay3 = accentColor * circle3 * circleOpacity * 0.8;
    vec3 overlay4 = primaryColor * circle4 * circleOpacity * 0.7;
    vec3 overlay5 = secondaryColor * circle5 * circleOpacity * 0.8;
    vec3 overlay6 = accentColor * circle6 * circleOpacity * 0.6;
    vec3 overlay7 = primaryColor * circle7 * circleOpacity * 0.7;
    vec3 overlay8 = secondaryColor * circle8 * circleOpacity * 0.5;

    // 전체 오버레이 합성
    vec3 totalOverlay = overlay1 + overlay2 + overlay3 + overlay4 + overlay5 + overlay6 + overlay7 + overlay8;

    // 블룸 효과 생성 (수학적으로 시뮬레이션)
    vec3 bloomColor = vec3(0.0);

    // 원 1에 블룸 적용
    float bloom1 = circle1 * 0.5;
    bloomColor += primaryColor * bloom1 * (1.0 - smoothstep(0.0, radius1 + 0.05, dist1));

    // 원 3에 블룸 적용
    float bloom3 = circle3 * 0.4;
    bloomColor += accentColor * bloom3 * (1.0 - smoothstep(0.0, radius3 + 0.05, dist3));

    // 원 5에 블룸 적용
    float bloom5 = circle5 * 0.3;
    bloomColor += secondaryColor * bloom5 * (1.0 - smoothstep(0.0, radius5 + 0.05, dist5));

    bloomColor *= bloomIntensity * 0.3;

    // 최종 색상 합성
    vec4 finalColor = baseColor;

    // 원들의 총 알파값 계산
    float totalAlpha = (circle1 + circle2 + circle3 + circle4 + circle5 + circle6 + circle7 + circle8) * circleOpacity * overlayAlpha * effectStrength;
    totalAlpha = clamp(totalAlpha, 0.0, 1.0);

    finalColor.rgb = totalOverlay + bloomColor;
    finalColor.a = totalAlpha;

    // 색조 조정
    float luminance = dot(finalColor.rgb, vec3(0.299, 0.587, 0.114));
    finalColor.rgb = mix(vec3(luminance), finalColor.rgb, 1.2);

    // 비네팅 (알파에만 적용)
    vec2 center = vec2(0.5, 0.5);
    float vignette = 1.0 - pow(distance(uv, center) * 0.9, 1.2);
    vignette = clamp(vignette, 0.6, 1.0);
    finalColor.a *= vignette;

    fragColor = finalColor;
}