/* Enter The Matrix by @kishimisu (2023) - https://www.shadertoy.com/view/cl3XRX

   Let me show you how deep the rabbit hole goes...

   This work is licensed under a Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License (https://creativecommons.org/licenses/by-nc-sa/4.0/deed.en)

/* 499 => 399 chars with the help of @Xor, @iapafoto, @FabriceNeyret & @coyote */
void mainImage(out vec4 I, vec2 u) {

    float   M    ,
            A    ,
            T    = iTime,
            R    ;
    for(    I    *= R; R++ < 66.;) {
    vec4    X    = iResolution.xyzz,

        p = A * normalize(vec4((u+u-X.xy) *
                      mat2(cos(A*sin(T*.1)*.3 + vec4(0,33,11,0))), X.y, 0));
        p.z += T;
        p.y = abs(abs(p.y) - 1.);

        X = fract(dot(X=ceil(p*4.), sin(X)) + X);
        X.g += 4.;
        M = 4.*pow(smoothstep(1., .5,
                       texture(iChannel0, (p.xz+ceil(T+X.x))/4.).a), 8.)-5.;

        A += p.y*.6 - (M+A+A+3.)/67.;

        I += (X.a + .5) * (X + A) * ( 1.4 - p.y ) / 2e2 / M / M / exp(A*.1);
    }
}
