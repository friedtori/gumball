#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// Rec. 709 luma; compensates for blur mixing hues before the slit is applied.
static half3 adjustSaturation(half3 c, half sat) {
    const half3 lumaW = half3(0.2126h, 0.7152h, 0.0722h);
    half l = dot(c, lumaW);
    half3 g = half3(l);
    return clamp(mix(g, c, sat), 0.0h, 1.0h);
}

static half3 adjustContrast(half3 c, half k) {
    return clamp((c - 0.5h) * k + 0.5h, 0.0h, 1.0h);
}

static float loopedX(float x, float width) {
    float w = max(width, 1.0f);
    float wrapped = fmod(x, w);
    if (wrapped < 0.0f) {
        wrapped += w;
    }

    // Avoid sampling exactly on the wrapped layer edge, which can pull in a 1px transparent seam.
    float inset = min(0.5f, w * 0.5f);
    return clamp(wrapped, inset, max(inset, w - inset));
}

static float mirroredLoopedX(float x, float width) {
    float w = max(width, 1.0f);
    float period = w * 2.0f;
    float wrapped = fmod(x, period);
    if (wrapped < 0.0f) {
        wrapped += period;
    }

    float mirrored = wrapped <= w ? wrapped : period - wrapped;
    float inset = min(0.5f, w * 0.5f);
    return clamp(mirrored, inset, max(inset, w - inset));
}

static half4 seamFeatherSample(SwiftUI::Layer layer, float2 position, float width, float featherWidth) {
    float w = max(width, 1.0f);
    float feather = min(max(featherWidth, 0.0f), w * 0.5f);
    float x = loopedX(position.x, w);
    half4 base = layer.sample(float2(x, position.y));

    if (feather <= 0.0f) {
        return base;
    }

    if (x < feather) {
        float t = x / feather;
        half4 other = layer.sample(float2(w - feather + x, position.y));
        return mix(other, base, half(t));
    }

    if (x > w - feather) {
        float t = (x - (w - feather)) / feather;
        half4 other = layer.sample(float2(x - (w - feather), position.y));
        return mix(base, other, half(t));
    }

    return base;
}

static half4 mirroredSeamFeatherSample(SwiftUI::Layer layer, float2 position, float width, float featherWidth) {
    float w = max(width, 1.0f);
    float feather = min(max(featherWidth, 0.0f), w * 0.5f);
    float period = w * 2.0f;
    float wrapped = fmod(position.x, period);
    if (wrapped < 0.0f) {
        wrapped += period;
    }

    float x = mirroredLoopedX(position.x, w);
    half4 base = layer.sample(float2(x, position.y));

    if (feather <= 0.0f) {
        return base;
    }

    float distanceToSeam = min(min(wrapped, abs(wrapped - w)), period - wrapped);
    if (distanceToSeam >= feather) {
        return base;
    }

    // Sample just across the nearest fold so the repeat is original -> mirrored -> original,
    // with the same feathered seam treatment as the plain loop.
    float seamX = wrapped < w * 0.5f ? 0.0f : (wrapped < w * 1.5f ? w : period);
    float otherWrapped = seamX + (seamX - wrapped);
    float otherX = mirroredLoopedX(otherWrapped, w);
    half4 other = layer.sample(float2(otherX, position.y));
    half t = half(distanceToSeam / feather);
    return mix(other, base, t);
}

[[ stitchable ]] half4 scrollSample(
    float2 position,
    SwiftUI::Layer layer,
    float layerWidth,
    float scrollOffset,
    float seamFeatherWidth
) {
    return mirroredSeamFeatherSample(layer, float2(position.x + scrollOffset, position.y), layerWidth, seamFeatherWidth);
}

// Colour-only post-processing (saturation, contrast, brightness) with no spatial quantization.
// Used by the Blur background style so it matches the slit-scan colour pipeline.
[[ stitchable ]] half4 colorAdjust(
    float2 position,
    SwiftUI::Layer layer,
    float postBlurSaturation,
    float postBlurContrast,
    float brightnessBoost
) {
    half4 c = layer.sample(position);
    half3 rgb = c.rgb;
    rgb = adjustSaturation(rgb, half(max(postBlurSaturation, 0.0f)));
    rgb = adjustContrast(rgb, half(max(postBlurContrast, 0.0f)));
    rgb = clamp(rgb * half(brightnessBoost), 0.0h, 1.0h);
    return half4(rgb, c.a);
}

// Run after `scrollSample`: the source moves under fixed strips, giving a morphing slit-scan feel.
[[ stitchable ]] half4 slitScan(
    float2 position,
    SwiftUI::Layer layer,
    float stripWidth,
    float postBlurSaturation,
    float postBlurContrast,
    float brightnessBoost   // 1.0 = no change; 1.25 in light mode
) {
    float w = max(stripWidth, 1.0f);
    float satK = max(postBlurSaturation, 0.0f);
    float conK = max(postBlurContrast, 0.0f);

    float quantizedX = floor(position.x / w) * w + (w * 0.5f);
    half4 c = layer.sample(float2(quantizedX, position.y));
    half3 rgb = c.rgb;
    rgb = adjustSaturation(rgb, half(satK));
    rgb = adjustContrast(rgb, half(conK));
    rgb = clamp(rgb * half(brightnessBoost), 0.0h, 1.0h);
    return half4(rgb, c.a);
}
