#version 460 core

#include <flutter/runtime_effect.glsl>

// 输入纹理（视频帧）
uniform sampler2D uTexture;
// 绿幕色度键参数
uniform float uThreshold;   // 色度键阈值（0-1，越低越激进）
uniform float uSoftness;    // 柔和过渡宽度
uniform vec2 uSize;         // 纹理尺寸

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    vec4 color = texture(uTexture, uv);

    // --- 绿幕色度键 (Chroma Key) ---
    // 目标绿幕颜色 (纯绿色)
    vec3 keyColor = vec3(0.0, 1.0, 0.0);

    // 计算当前像素与绿幕颜色在色度空间中的距离
    // 使用 YCbCr 色度空间做色度差计算更稳定
    float cb_key = -0.168736 * keyColor.r - 0.331264 * keyColor.g + 0.5 * keyColor.b;
    float cr_key =  0.5 * keyColor.r - 0.418688 * keyColor.g - 0.081312 * keyColor.b;

    float cb_pixel = -0.168736 * color.r - 0.331264 * color.g + 0.5 * color.b;
    float cr_pixel =  0.5 * color.r - 0.418688 * color.g - 0.081312 * color.b;

    // 色度距离
    float chromaDist = distance(vec2(cb_pixel, cr_pixel), vec2(cb_key, cr_key));

    // smoothstep 柔和边缘过渡
    float alpha = smoothstep(uThreshold, uThreshold + uSoftness, chromaDist);

    // 去溢色 (despill)：去除主体边缘的绿色溢出
    // 限制绿色通道不超过红蓝平均值
    float despill = color.g - max(color.r, color.b);
    if (despill > 0.0) {
        color.g -= despill * alpha; // 只对非绿幕区域做部分去溢色
        color.g -= despill * (1.0 - alpha) * 0.8; // 对绿幕边缘做更强去溢色
    }

    // 输出：保留原色，修改透明度
    fragColor = vec4(color.rgb * alpha, alpha);
}
