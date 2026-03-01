// Original by LocalThunk (https://localthunk.com/)
// optimization and cleanup work work done by me (wgrav) and xandr
// Consider this all rights reserved, to them, as it's a direct port, taken from the game itself
// Please consider buying their game, it's a work of art

// It takes a few seconds for the vortex to appear (~3), this is a part of the game's intro
// All comments besides these and the ones marked as "wgrav note:" are from the original shader
// Also, gamma correction was applied (done previously by love2d's pipeline)

#define MID_FLASH 0. // wgrav note: turning this up will crank up the brightness, into, well, a flash
#define VORT_SPEED .8 // wgrav note: this changes the speed of which the swirl swirls
#define VORT_OFFSET 0. // wgrav note: this doesn't really do anything, it seemingly adjusts the time offset
#define PIXEL_SIZE_FAC 700. // wgrav note: change this number to adjust the effective resolution

const vec4 BLUE  = vec4(pow(vec3(0., 157./255., 255./255.), vec3(2.2)), 1.);
const vec4 RED   = vec4(pow(vec3(254./255., 95./255., 85./255.), vec3(2.2)), 1.);
const vec4 BLACK = vec4(pow(0.6*vec3(79./255., 99./255., 103./255.), vec3(2.2)), 1.);

void mainImage(out vec4 fragColor, in vec2 fragCord) {
    float res_len = length(iResolution.xy);

    //Convert to UV coords (0-1) and floor for pixel effect
    float pixel_size = res_len/PIXEL_SIZE_FAC;
    vec2 uv = (floor(fragCord.xy*(1./pixel_size))*pixel_size - 0.5*iResolution.xy)/res_len;
    float uv_len = length(uv);

    //Adding in a center swirl, changes with time
    float speed = iTime*VORT_SPEED;
    float clamped_speed = min(6., speed);
    float new_pixel_angle = atan(uv.y, uv.x) + (2.2 + 0.4*clamped_speed)*uv_len - 1. -  speed*0.05 - clamped_speed*speed*0.02 + VORT_OFFSET;
    vec2 mid = normalize(iResolution.xy)*0.5;
    vec2 sv = vec2((uv_len * cos(new_pixel_angle) + mid.x), (uv_len * sin(new_pixel_angle) + mid.y)) - mid;

    //Now add the smoke effect to the swirled UV
    sv *= 30.; // wgrav note: change this number to adjust the size of of the swirl
    speed = iTime* 6. *VORT_SPEED + VORT_OFFSET + 1033.;
    vec2 uv2 = vec2(sv.x+sv.y);

    for(int i=0; i < 5; i++) { // wgrav note: change the number of iterations to increase or decrease detail. if you turn it up high enough, it becomes a noise generator
        uv2 += sin(max(sv.x, sv.y)) + sv;
        sv  += 0.5*vec2(cos(5.1123314 + 0.353*uv2.y + speed*0.131121),sin(uv2.x - 0.113*speed));
        sv  -= cos(sv.x + sv.y) - sin(sv.x*0.711 - sv.y);
    }

    //Make the smoke amount range from 0 - 2
    float smoke_res =min(2., max(-2., 1.5 + length(sv)*0.12 - 0.17*(min(10.,iTime*1.2 - 4.))));
    float smoke_adj = (smoke_res - 0.2)*0.6 + 0.2;
    smoke_res = mix(smoke_adj, smoke_res, step(0.2, smoke_res));

    float c1p = max(0., 1. - 2.*abs(1.-smoke_res));
    float c2p = max(0., 1. - 2.*(smoke_res));
    float cb = 1. - min(1., c1p + c2p);
    vec4 ret_col = RED*c1p + BLUE*c2p + vec4(cb*BLACK.rgb, cb*RED.a);
    float max_cp = max(c1p, c2p);
    float mod_flash = max(MID_FLASH*0.8, max_cp*5. - 4.4) + MID_FLASH*max_cp;
    vec4 final = ret_col*(1. - mod_flash) + mod_flash;
    fragColor = vec4(pow(final.rgb, vec3(1.0/2.2)), final.a);
}
