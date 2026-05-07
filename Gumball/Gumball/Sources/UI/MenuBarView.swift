import SwiftUI
import AppKit
import CoreImage

enum GumballOptionKeys {
    static let backgroundStyle = "menuBarBackgroundStyle"
    static let backgroundScrollDuration = "menuBarBackgroundScrollDuration"
    static let keepPinnedPopoverVisible = "keepPinnedPopoverVisible"
}

enum MenuBarBackgroundStyle: String, CaseIterable, Identifiable {
    case blur
    case slitScan
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blur: "Blur"
        case .slitScan: "Slit-scan"
        case .none: "None"
        }
    }
}

/// Sends commands to the system "now playing" app via MediaRemote.
/// One-shot, no background work, zero power cost at rest.
private enum PlaybackController {
    private typealias SendCommandFn = @convention(c) (UInt32, AnyObject?) -> Bool

    private static let sendCommand: SendCommandFn? = {
        guard
            let handle = dlopen(
                "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                RTLD_LAZY
            ),
            let sym = dlsym(handle, "MRMediaRemoteSendCommand")
        else { return nil }
        return unsafeBitCast(sym, to: SendCommandFn.self)
    }()

    static func togglePlayPause() { _ = sendCommand?(2, nil) }
    static func nextTrack()       { _ = sendCommand?(4, nil) }
    static func previousTrack()   { _ = sendCommand?(5, nil) }
}

/// Bundle-loaded SVG badge with a one-shot NSImage cache per (resource, isTemplate) pair.
/// Replaces what used to be three near-identical badge views (RYM / AOTY / Last.fm).
/// `isTemplate = true` makes AppKit ignore the SVG fill and render in the foreground colour
/// (i.e. adaptive dark/light); leave `false` to keep the SVG's original colours.
private struct IconBadge: View {
    let resource: String
    var size: CGSize = CGSize(width: 14, height: 14)
    var isTemplate: Bool = false
    var fallbackSystemName: String = "magnifyingglass"

    @MainActor private static var cache: [CacheKey: NSImage] = [:]

    private struct CacheKey: Hashable {
        let resource: String
        let isTemplate: Bool
    }

    @MainActor
    private static func image(for key: CacheKey) -> NSImage? {
        if let cached = cache[key] { return cached }
        guard
            let url = Bundle.main.url(forResource: key.resource, withExtension: "svg"),
            let img = NSImage(contentsOf: url)
        else { return nil }
        img.isTemplate = key.isTemplate
        cache[key] = img
        return img
    }

    var body: some View {
        if let image = Self.image(for: CacheKey(resource: resource, isTemplate: isTemplate)) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
        } else {
            Image(systemName: fallbackSystemName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

/// Bottom-row Last.fm profile link (badge + "Last.fm connected" label).
private struct LastFMProfileLink: View {
    let url: URL?
    @State private var isHovering = false

    var body: some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            Label {
                Text("connected")
                    .font(.system(size: 10, weight: .semibold).smallCaps())
                    .foregroundStyle(isHovering && url != nil ? .primary : .secondary)
            } icon: {
                IconBadge(resource: "last-fm-logo-icon", size: CGSize(width: 18, height: 10), isTemplate: true)
                    .opacity(isHovering ? 1.0 : 0.55)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering && url != nil ? Color.secondary.opacity(0.12) : Color.clear)
        }
        .onHover { isHovering = $0 }
        .help(url == nil ? "Last.fm username not available yet" : "Open Last.fm profile")
    }
}

/// Middle row of external music-database links (RYM, AOTY, …).
private struct ExternalLinksRow: View {
    var rymURL: URL? = nil
    var aotyURL: URL? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let rymURL {
                ExternalLinkChip(url: rymURL, help: "Open on RateYourMusic") {
                    IconBadge(resource: "rym-logo")
                } label: {
                    Text("RYM")
                }
            }
            if let aotyURL {
                ExternalLinkChip(url: aotyURL, help: "Open on Album of the Year") {
                    IconBadge(resource: "aoty-logo", isTemplate: true)
                } label: {
                    Text("AOTY")
                }
            }
        }
    }
}

private struct ExternalLinkChip<Icon: View, Label: View>: View {
    let url: URL
    let help: String
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let label: () -> Label
    @State private var isHovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 4) {
                icon()
                    .opacity(isHovering ? 1.0 : 0.7)
                label()
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovering ? .primary : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 72)
        .background {
            if #available(macOS 26.0, *) {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular.tint(.white.opacity(0.3)).interactive(), in: Capsule())
                    .opacity(isHovering ? 1.0 : 0.85)
            } else {
                Capsule()
                    .fill(Color.secondary.opacity(isHovering ? 0.18 : 0.1))
            }
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

private struct LastFMMetadataLink: View {
    enum Role {
        case title
        case artist
        case album

        var font: Font {
            switch self {
            case .title: .system(size: 14.3, weight: .semibold)
            case .artist: .system(size: 13.2)
            case .album: .system(size: 11)
            }
        }

        var normalOpacity: Double {
            switch self {
            case .title: 1
            case .artist: 0.7
            case .album: 0.5
            }
        }
    }

    let text: String
    let url: URL?
    let role: Role
    var lineLimit: Int = 1

    @State private var isHovering = false

    var body: some View {
        if let url {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                styledText
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 0)
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? Color.secondary.opacity(0.12) : Color.clear)
            }
            .onHover { hovering in
                isHovering = hovering
            }
            .help("Open on Last.fm")
        } else {
            styledText
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var styledText: some View {
        Text(text)
            .font(role.font)
            .foregroundStyle(.primary)
            .opacity(isHovering && url != nil ? 1 : role.normalOpacity)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MenuActionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(isHovering ? .primary : .secondary)
            } icon: {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(isHovering ? .primary : .secondary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering ? Color.secondary.opacity(0.12) : Color.clear)
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private struct MenuIconActionButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: 18, height: 18)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering ? Color.secondary.opacity(0.12) : Color.clear)
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .help(help)
    }
}

/// Play/pause, skip, and love controls: same hover treatment as `MenuIconActionButton` + metadata rows.
private struct PopoverHoverControlButton<Content: View>: View {
    let help: String
    var isEnabled: Bool
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content

    @State private var isHovering = false

    var iconSize: CGFloat = 18

    init(
        help: String,
        isEnabled: Bool = true,
        iconSize: CGFloat = 18,
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.help = help
        self.isEnabled = isEnabled
        self.iconSize = iconSize
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            content(isHovering)
                .frame(width: iconSize, height: iconSize, alignment: .center)
                .frame(width: 34, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .frame(width: 34, height: 30)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isHovering && isEnabled ? Color.secondary.opacity(0.12) : Color.clear)
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .help(help)
        .disabled(!isEnabled)
        .opacity(!isEnabled ? 0.35 : 1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Slit-scan popover background (Metal `layerEffect`; artwork tile is normal)

private enum SlitScanArtwork {
    /// Slit scan only for the popover background (artwork tile stays unshaded).
    static let backgroundStripWidth: CGFloat = 12
    /// Blur is applied to the art before the slit-scan shader (so ribbons see soft color columns).
    static let backgroundBlurRadius: CGFloat = 26
    /// Applied inside `slitScan` after the layer sample (post-blur), not via SwiftUI color filters.
    static let backgroundPostBlurSaturation: Double = 1.4
    static let backgroundPostBlurContrast: Double = 1.2
    /// Light mode needs a harder push to read through the bright glass chrome.
    static let backgroundPostBlurSaturationLight: Double = 1.5
    static let backgroundPostBlurContrastLight: Double = 1.3
    static let seamFeatherWidth: CGFloat = 16
    /// The moving layer invalidates SwiftUI; tie FPS to speed to keep slower motion cheap.
    static func scrollFramesPerSecond(duration: TimeInterval) -> TimeInterval {
        switch duration {
        case 0:  0
        case 30: 4
        case 20: 8
        case 8:  15
        default: 4
        }
    }

    private static let blurContext = CIContext()

    static func scrollSampleOffset(layerWidth: CGFloat) -> CGSize {
        CGSize(width: max(layerWidth * 2, 1), height: 0)
    }

    static func activeSeamFeatherWidth(forDuration duration: TimeInterval) -> CGFloat {
        duration > 0 ? seamFeatherWidth : 0
    }

    static func blurredImage(from image: NSImage) -> NSImage {
        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return image }

        let input = CIImage(cgImage: cgImage)
        guard
            let filter = CIFilter(name: "CIGaussianBlur")
        else { return image }

        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(backgroundBlurRadius, forKey: kCIInputRadiusKey)

        guard
            let output = filter.outputImage?.cropped(to: input.extent),
            let blurred = blurContext.createCGImage(output, from: input.extent)
        else { return image }

        return NSImage(cgImage: blurred, size: image.size)
    }
}

private struct ScrollOffsetTimeline<Content: View>: View {
    var scrollDuration: TimeInterval = 0
    var isPaused: Bool = false
    @ViewBuilder var content: (_ scrollOffset: CGFloat, _ layerWidth: CGFloat) -> Content

    @State private var activeScrollTime: TimeInterval = 0
    @State private var lastResumeDate = Date()
    @State private var clockPaused: Bool?

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            if isPaused || scrollDuration <= 0 {
                content(scrollOffset(at: Date(), width: width), width)
            } else {
                TimelineView(.periodic(from: .now, by: 1 / SlitScanArtwork.scrollFramesPerSecond(duration: scrollDuration))) { context in
                    content(scrollOffset(at: context.date, width: width), width)
                }
            }
        }
        .clipped()
        .onAppear {
            syncClock(paused: isPaused, now: Date())
        }
        .onChange(of: isPaused) {
            syncClock(paused: isPaused, now: Date())
        }
    }

    private func scrollOffset(at date: Date, width: CGFloat) -> CGFloat {
        guard scrollDuration > 0 else { return 0 }
        let phase = scrollTime(at: date)
            .truncatingRemainder(dividingBy: scrollDuration) / scrollDuration
        // Sweep 2× width to complete one full mirror cycle (forward + backward),
        // so the wrap-around lands back at the seam and the loop is seamless.
        return -CGFloat(phase) * width * 2
    }

    private func scrollTime(at date: Date) -> TimeInterval {
        guard !isPaused else { return activeScrollTime }
        return activeScrollTime + max(date.timeIntervalSince(lastResumeDate), 0)
    }

    private func syncClock(paused: Bool, now: Date) {
        guard clockPaused != paused else { return }

        if let clockPaused {
            if paused && !clockPaused {
                activeScrollTime += max(now.timeIntervalSince(lastResumeDate), 0)
            } else if !paused && clockPaused {
                lastResumeDate = now
            }
        } else {
            lastResumeDate = now
        }

        clockPaused = paused
    }
}

private struct StaticArtworkLayer: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .clipped()
    }
}

private struct BlurredArtworkBackground: View {
    let image: NSImage
    var scrollDuration: TimeInterval = 0
    var isPaused: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    private var effectiveSaturation: Float { colorScheme == .light ? Float(SlitScanArtwork.backgroundPostBlurSaturationLight) : Float(SlitScanArtwork.backgroundPostBlurSaturation) }
    private var effectiveContrast: Float { colorScheme == .light ? Float(SlitScanArtwork.backgroundPostBlurContrastLight) : Float(SlitScanArtwork.backgroundPostBlurContrast) }

    var body: some View {
        ScrollOffsetTimeline(scrollDuration: scrollDuration, isPaused: isPaused) { offset, layerWidth in
            StaticArtworkLayer(image: image)
                .layerEffect(
                    ShaderLibrary.scrollAndColorAdjust(
                        .float(Float(layerWidth)),
                        .float(Float(offset)),
                        .float(Float(SlitScanArtwork.activeSeamFeatherWidth(forDuration: scrollDuration))),
                        .float(effectiveSaturation),
                        .float(effectiveContrast),
                        .float(1.0)
                    ),
                    maxSampleOffset: SlitScanArtwork.scrollSampleOffset(layerWidth: layerWidth)
                )
        }
    }
}

private struct SlitScannedArtwork: View {
    let image: NSImage
    var stripWidth: CGFloat
    /// Passed into `slitScan` (1.0 = no change; above 1 boosts chroma for blurred layers).
    var postBlurSaturation: Double = 1.0
    var postBlurContrast: Double = 1.0
    var scrollDuration: TimeInterval = 0
    var isPaused: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    /// -25% brightness in light mode to create contrast against the bright glass chrome.
    private var brightnessBoost: Float { 1.0 }
    private var effectiveSaturation: Float { colorScheme == .light ? Float(SlitScanArtwork.backgroundPostBlurSaturationLight) : Float(postBlurSaturation) }
    private var effectiveContrast: Float { colorScheme == .light ? Float(SlitScanArtwork.backgroundPostBlurContrastLight) : Float(postBlurContrast) }

    var body: some View {
        ScrollOffsetTimeline(scrollDuration: scrollDuration, isPaused: isPaused) { offset, layerWidth in
            StaticArtworkLayer(image: image)
                .layerEffect(
                    ShaderLibrary.scrollAndSlitScan(
                        .float(Float(layerWidth)),
                        .float(Float(offset)),
                        .float(Float(SlitScanArtwork.activeSeamFeatherWidth(forDuration: scrollDuration))),
                        .float(Float(stripWidth)),
                        .float(effectiveSaturation),
                        .float(effectiveContrast),
                        .float(brightnessBoost)
                    ),
                    maxSampleOffset: SlitScanArtwork.scrollSampleOffset(layerWidth: layerWidth)
                )
        }
    }
}

/// Menu bar pop-over panel.
struct GumballMenuBarCommands: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var status = AppStatusBridge.shared
    @AppStorage(GumballOptionKeys.backgroundStyle) private var backgroundStyle = MenuBarBackgroundStyle.slitScan.rawValue
    private let backgroundOpacityLight = Design.Background.opacityLight
    private let backgroundOpacityDark = Design.Background.opacityDark
    @AppStorage(GumballOptionKeys.backgroundScrollDuration) private var backgroundScrollDuration = 30.0
    @State private var lastArtworkImage: NSImage?
    @State private var backgroundArtworkImage: NSImage?
    @State private var fadingArtworkImage: NSImage?
    @State private var fadingArtworkOpacity = 0.0
    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            nowPlayingSection
            controlsSection
            authStatusRow
                .padding(.vertical, 8)
                .padding(.leading, Design.Artwork.metadataLeading)
                .padding(.trailing, Design.Popover.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
                .padding(.horizontal, Design.Popover.width * Design.Popover.dividerInsetRatio)
            actionSection
        }
        .frame(width: Design.Popover.width)
        .background {
            albumArtBackground
        }
        .clipped()
        .overlay {
            // Inner glow — white stroke blurred inward for a lit-from-within rim effect.
            // Only in light mode; dark mode's glass already provides sufficient depth.
            if colorScheme == .light {
                Rectangle()
                    .stroke(Color.white.opacity(0.4), lineWidth: 12)
                    .blur(radius: 8)
                    .blendMode(.screen)
            }
        }
        .onReceive(status.$artworkImage) { image in
            handleArtworkTransition(to: image)
        }
        .onAppear {
            isVisible = true
            handleArtworkTransition(to: status.artworkImage)
        }
        .onDisappear {
            isVisible = false
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    private var albumArtBackground: some View {
        if (MenuBarBackgroundStyle(rawValue: backgroundStyle) ?? .slitScan) != .none {
            ZStack {
                if let fadingArtworkImage {
                    albumArtBackgroundLayer(image: fadingArtworkImage)
                        .opacity(fadingArtworkOpacity)
                }
                if let img = backgroundArtworkImage {
                    albumArtBackgroundLayer(image: img)
                        .opacity(colorScheme == .dark ? backgroundOpacityDark : backgroundOpacityLight)
                }
            }
        }
    }

    @ViewBuilder
    private func albumArtBackgroundLayer(image: NSImage) -> some View {
        switch MenuBarBackgroundStyle(rawValue: backgroundStyle) ?? .slitScan {
        case .blur:
            BlurredArtworkBackground(
                image: image,
                scrollDuration: backgroundScrollDuration,
                isPaused: !status.isPlaying || !isVisible
            )
        case .slitScan:
            SlitScannedArtwork(
                image: image,
                stripWidth: SlitScanArtwork.backgroundStripWidth,
                postBlurSaturation: SlitScanArtwork.backgroundPostBlurSaturation,
                postBlurContrast: SlitScanArtwork.backgroundPostBlurContrast,
                scrollDuration: backgroundScrollDuration,
                isPaused: !status.isPlaying || !isVisible
            )
        case .none:
            EmptyView()
        }
    }

    private func handleArtworkTransition(to image: NSImage?) {
        guard !sameImage(lastArtworkImage, image) else { return }

        if let backgroundArtworkImage {
            fadingArtworkImage = backgroundArtworkImage
            fadingArtworkOpacity = colorScheme == .dark ? backgroundOpacityDark : backgroundOpacityLight
            withAnimation(.easeInOut(duration: Design.Animation.crossfade)) {
                fadingArtworkOpacity = 0
            }
            clearFadingArtwork(after: 0.75, image: backgroundArtworkImage)
        }

        backgroundArtworkImage = image.map { SlitScanArtwork.blurredImage(from: $0) }
        lastArtworkImage = image
    }

    private func clearFadingArtwork(after seconds: TimeInterval, image: NSImage) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if sameImage(fadingArtworkImage, image) {
                fadingArtworkImage = nil
            }
        }
    }

    private func sameImage(_ lhs: NSImage?, _ rhs: NSImage?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            // Reference equality fast path; fall back to data comparison so identical
            // artwork arriving as new NSImage objects (--no-diff adapter) doesn't
            // trigger a spurious crossfade on every play/pause event.
            lhs === rhs || lhs.tiffRepresentation == rhs.tiffRepresentation
        default:
            false
        }
    }

    // MARK: - Now Playing

    private var nowPlayingSection: some View {
        HStack(alignment: .center, spacing: 10) {
            artworkView
                .frame(width: Design.Artwork.size, height: Design.Artwork.size)
                .clipShape(RoundedRectangle(cornerRadius: Design.Artwork.cornerRadius))
                .shadow(color: .black.opacity(0.22), radius: 7, x: 0, y: 3)
                .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 0) {
                if let title = status.trackTitle {
                    LastFMMetadataLink(
                        text: title,
                        url: lastFMTrackURL,
                        role: .title,
                        lineLimit: 2
                    )
                } else {
                    Text(status.isPlaying ? "Playing" : "Nothing playing")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                if let artist = status.trackArtist {
                    LastFMMetadataLink(
                        text: artist,
                        url: lastFMArtistURL,
                        role: .artist
                    )
                    .padding(.top, 1)
                }
                if let album = status.trackAlbum {
                    LastFMMetadataLink(
                        text: album,
                        url: lastFMAlbumURL,
                        role: .album
                    )
                    .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 74)
        .padding(.horizontal, Design.Popover.inset)
        .padding(.top, Design.Popover.inset)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var artworkView: some View {
        if let img = status.artworkImage {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .grayscale(status.isPlaying ? 0 : 1)
                .overlay {
                    if !status.isPlaying {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
                    }
                }
        } else {
            RoundedRectangle(cornerRadius: Design.Artwork.cornerRadius)
                .fill(Color.secondary.opacity(0.15))
                .overlay {
                    Image(systemName: status.isPlaying ? "music.note" : "pause.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
        }
    }

    // MARK: - Playback Controls

    private var controlsSection: some View {
        HStack(spacing: 12) {
            PopoverHoverControlButton(help: "Previous track", action: {
                PlaybackController.previousTrack()
            }) { isHovering in
                Image(systemName: "backward.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(isHovering ? .primary : .secondary)
            }

            PopoverHoverControlButton(help: "Play / Pause", iconSize: 26, action: {
                PlaybackController.togglePlayPause()
            }) { isHovering in
                Image(systemName: status.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(isHovering ? Color.primary : Color.primary.opacity(Design.Hover.primaryRestingOpacity))
            }

            PopoverHoverControlButton(help: "Next track", action: {
                PlaybackController.nextTrack()
            }) { isHovering in
                Image(systemName: "forward.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(isHovering ? .primary : .secondary)
            }

            loveHoverButton
        }
        .padding(.top, 2)
        .padding(.bottom, 10)
        .padding(.leading, Design.Artwork.metadataLeading)
    }

    @ViewBuilder
    private var loveHoverButton: some View {
        let loved = status.isTrackLoved
        let hasTrack = status.trackTitle != nil
        let isLoading = hasTrack && loved == nil
        let lastfmRed = Color(red: 213/255, green: 16/255, blue: 7/255)

        PopoverHoverControlButton(
            help: loved == true ? "Unlove on Last.fm" : "Love on Last.fm",
            isEnabled: hasTrack && !isLoading,
            action: {
                Task {
                    if loved == true {
                        await AppStatusBridge.shared.unloveCurrentTrack?()
                    } else {
                        await AppStatusBridge.shared.loveCurrentTrack?()
                    }
                }
            }
        ) { isHovering in
            Image(systemName: loved == true ? "heart.fill" : "heart")
                .font(.system(size: 15))
                .foregroundStyle(
                    loved == true
                        ? lastfmRed.opacity(isHovering ? 1 : 0.88)
                        : (isHovering ? Color.primary : Color.secondary)
                )
                .offset(y: 1)
        }
        .animation(.easeInOut(duration: Design.Animation.love), value: loved)
    }

    // MARK: - Status

    @ViewBuilder
    private var authStatusRow: some View {
        if status.authStatus == .authorized {
            ExternalLinksRow(rymURL: rymAlbumURL, aotyURL: aotyAlbumURL)
        } else {
            Label {
                Text(status.authStatus.rawValue)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: authStatusIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(authStatusColor)
            }
        }
    }

    private var lastFMProfileURL: URL? {
        guard
            let username = status.lastFMUsername,
            let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "https://www.last.fm/user/\(encodedUsername)")
    }

    private var lastFMArtistURL: URL? {
        guard let artist = lastFMPathComponent(status.trackArtist) else { return nil }
        return URL(string: "https://www.last.fm/music/\(artist)")
    }

    private var lastFMAlbumURL: URL? {
        guard
            let artist = lastFMPathComponent(status.trackArtist),
            let album = lastFMPathComponent(status.trackAlbum)
        else { return nil }
        return URL(string: "https://www.last.fm/music/\(artist)/\(album)")
    }

    private var lastFMTrackURL: URL? {
        guard
            let artist = lastFMPathComponent(status.trackArtist),
            let track = lastFMPathComponent(status.trackTitle)
        else { return nil }
        return URL(string: "https://www.last.fm/music/\(artist)/_/\(track)")
    }

    private var rymAlbumURL: URL? {
        guard
            let artist = status.trackArtist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty,
            let album = status.trackAlbum?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty
        else { return nil }
        let query = "\\ site:rateyourmusic.com \"\(artist)\" \"\(album)\""
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://duckduckgo.com/?q=\(encoded)")
    }

    private var aotyAlbumURL: URL? {
        guard
            let artist = status.trackArtist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty,
            let album = status.trackAlbum?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty
        else { return nil }
        let query = "\\ site:albumoftheyear.org \"\(artist)\" \"\(album)\""
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://duckduckgo.com/?q=\(encoded)")
    }

    private func lastFMPathComponent(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return trimmed.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private var authStatusIcon: String {
        switch status.authStatus {
        case .authorized: "checkmark.circle.fill"
        case .authorizing: "arrow.clockwise.circle"
        case .failed: "exclamationmark.circle.fill"
        case .notConfigured: "questionmark.circle"
        }
    }

    private var authStatusColor: Color {
        switch status.authStatus {
        case .authorized: .green
        case .authorizing: .orange
        case .failed: .red
        case .notConfigured: .secondary
        }
    }

    // MARK: - Actions

    private var actionSection: some View {
        HStack(spacing: 14) {
            if status.authStatus == .authorized {
                LastFMProfileLink(url: lastFMProfileURL)
            }
            Spacer()
            MenuIconActionButton(systemImage: "gearshape", help: "Options") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "options")
            }

            MenuIconActionButton(systemImage: "power", help: "Quit Gumball") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, Design.Popover.inset)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

#Preview {
    let status = AppStatusBridge.shared
    status.isPlaying = true
    status.trackTitle = "Idioteque"
    status.trackArtist = "Radiohead"
    status.trackAlbum = "Kid A"
    status.authStatus = .authorized
    status.lastFMUsername = "rj"
    status.isTrackLoved = true

    return GumballMenuBarCommands()
}
