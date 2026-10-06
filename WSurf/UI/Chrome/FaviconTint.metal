// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] half4 wsurfFaviconTint(float2 position, half4 color, half4 tint) {
    const half3 luminance = half3(0.2126h, 0.7152h, 0.0722h);
    half gray = dot(color.rgb, luminance);
    half3 chroma = tint.rgb - dot(tint.rgb, luminance);
    half3 toned = clamp(half3(gray) + chroma * color.a, half3(0), half3(color.a));
    return half4(toned * tint.a, color.a * tint.a);
}
