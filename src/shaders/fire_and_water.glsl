///////////////////////////////////
///广州智子数字科技有限公司       ///
///QQ：6363866                  ///
///从原理上一步步的解析          ///
///知识点：                     ///
///1. 高亮粒子的计算方法         ///
///2. 圆周分布轨道函数           ///
///3. 粒子大小依次改变模拟拖尾   ///
//////////////////////////////////

const float PI = 3.14159265857;
float speedfactor = 1.0; //旋转速度因子。<1.0 变慢. >1.0变快；
float unit = PI/280.; //每个粒子在圆周上的间隔距离
const float particlenums = 45.; //粒子数量。（粒子增多的同时请注意调整亮度因子.代码下行给出了粗略的计算以保证调整粒子数时可以不过亮）
float intensityfactor = 1./particlenums/15000.;

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    // Normalized pixel coordinates (from 0 to 1)
    vec2 uv = fragCoord/iResolution.xy;
    float aspect = iResolution.x/iResolution.y;
    uv = (uv - vec2(0.5)) * vec2(aspect,1.); //把坐标原点移动到画布中心,并根据画布宽高比修正为正圆
    //uv-=0.5; //把坐标原点移动到画布中心


    vec3 color = vec3(0.);

    for(float i=0.;i<particlenums;i++){
        float t = unit*i+iTime*speedfactor; //根据粒子编号(i)的差异让粒子在圆周上固定角度间隔分布，通过引入iTime形成动画效果
        vec2 orbit = vec2(sin(t),cos(t))*0.35; //圆周分布,运动轨道

        vec2 fuv = 1.25*uv + orbit; //红色火焰粒子uv定位
        vec3 fire = vec3(.7,.2,.1)/vec3(length(fuv))*pow(i,2.); //颜色发光效果计算函数。根据粒子编号来依次改变粒子大小，形成视觉上的粒子拖尾效果。
        color+=fire; //叠加红色粒子色彩

        //蓝色粒子效果同火焰粒子效果代码注释
        vec2 wuv = 1.25*uv - orbit;
        vec3 water = vec3(.1,.2,.7)/vec3(length(wuv))*pow(i,2.);
        color+=water;
    }

    // Output to screen
    fragColor = vec4(color*intensityfactor,1.0);  //color*intensityfactor 通过降低粒子叠加亮度来看最终效果。大家可以调整intensityfactor为不同的值看效果变化
}
