#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// Rec. 709 luma; compensates for blur mixing hues before the slit is applied.
static half3 adjustSaturation(half3 c, half sat) {
    const half3 lumaW = half3(0.2126h, 0.7152h, 0.0722h);
    half l = dot(c, lumaW);
    return clamp(mix(half3(l), c, sat), 0.0h, 1.0h);
}

static half3 adjustContrast(half3 c, half k) {
    return clamp((c - 0.5h) * k + 0.5h, 0.0h, 1.0h);
}

static float mirroredLoopedX(float x, float width) {
    float w = max(width, 1.0f);
    float period = w * 2.0f;
    float wrapped = fmod(x, period);
    if (wrapped < 0.0f) wrapped += period;
    float mirrored = wrapped <= w ? wrapped : period - wrapped;
    float inset = min(0.5f, w * 0.5f);
    return clamp(mirrored, inset, max(inset, w - inset));
}

static half4 mirroredSeamFeatherSample(SwiftUI::Layer layer, float2 position, float width, float featherWidth) {
    float w = max(width, 1.0f);
    float feather = min(max(featherWidth, 0.0f), w * 0.5f);
    float period = w * 2.0f;
    float wrapped = fmod(position.x, period);
    if (wrapped < 0.0f) wrapped += period;

    float x = mirroredLoopedX(position.x, w);
    half4 base = layer.sample(float2(x, position.y));

    if (feather <= 0.0f) return base;

    float distanceToSeam = min(min(wrapped, abs(wrapped - w)), period - wrapped);
    if (distanceToSeam >= feather) return base;

    float seamX = wrapped < w * 0.5f ? 0.0f : (wrapped < w * 1.5f ? w : period);
    float otherWrapped = seamX + (seamX - wrapped);
    float otherX = mirroredLoopedX(otherWrapped, w);
    half4 other = layer.sample(float2(otherX, position.y));
    return mix(other, base, half(distanceToSeam / feather));
}

static half3 colorAdjust(half3 rgb, float saturation, float contrast, float brightness) {
    rgb = adjustSaturation(rgb, half(max(saturation, 0.0f)));
    rgb = adjustContrast(rgb, half(max(contrast, 0.0f)));
    return clamp(rgb * half(brightness), 0.0h, 1.0h);
}

// Single-pass slit-scan: scroll + mirror + strip quantization + colour — replaces
// the old scrollSample → slitScan two-pass chain, halving GPU render passes per frame.
[[ stitchable ]] half4 scrollAndSlitScan(
    float2 position,
    SwiftUI::Layer layer,
    float layerWidth,
    float scrollOffset,
    float seamFeatherWidth,
    float stripWidth,
    float saturation,
    float contrast,
    float brightness
) {
    // Quantize to strip centre in panel space, then scroll that sample point.
    float w = max(stripWidth, 1.0f);
    float quantizedX = floor(position.x / w) * w + (w * 0.5f);
    half4 c = mirroredSeamFeatherSample(layer, float2(quantizedX + scrollOffset, position.y), layerWidth, seamFeatherWidth);
    return half4(colorAdjust(c.rgb, saturation, contrast, brightness), c.a);
}

// Single-pass blur background: scroll + mirror + colour (no strip quantization).
[[ stitchable ]] half4 scrollAndColorAdjust(
    float2 position,
    SwiftUI::Layer layer,
    float layerWidth,
    float scrollOffset,
    float seamFeatherWidth,
    float saturation,
    float contrast,
    float brightness
) {
    half4 c = mirroredSeamFeatherSample(layer, float2(position.x + scrollOffset, position.y), layerWidth, seamFeatherWidth);
    return half4(colorAdjust(c.rgb, saturation, contrast, brightness), c.a);
}
