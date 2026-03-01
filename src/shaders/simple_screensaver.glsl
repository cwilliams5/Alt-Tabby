void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
  vec2 uv = fragCoord.xy / iResolution.xy;
  uv.y = uv.y * ( iResolution.x / iResolution.y );
  float tt = 1024.*fract( iTime / 16384. );
  vec4 c = vec4(  cos( ( uv.x*uv.y + uv.y + 5.*tt ) * 3.),
                  cos( ( 3.*uv.y*uv.x + 7.*tt ) * 2.0 ),
                  cos( sin(tt)*(1.-uv.x-uv.y)*3. ), 1 );
  fragColor = c*vec4( .5, .5, .5, 1 ) + vec4( .5, .5, .5, 0 );
}
