import SwiftUI
import AppKit

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

private struct LastFMBadge: View {
    private static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "last-fm-logo-icon", withExtension: "svg") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 10)
        } else {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

private struct LastFMConnectedRow: View {
    let url: URL?
    @State private var isHovering = false

    var body: some View {
        Button {
            if let url {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Label {
                Text("Last.fm connected")
                    .font(.system(size: 12))
                    .foregroundStyle(isHovering && url != nil ? .primary : .secondary)
            } icon: {
                LastFMBadge()
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
        .onHover { hovering in
            isHovering = hovering
        }
        .help(url == nil ? "Last.fm username not available yet" : "Open Last.fm profile")
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

/// Menu bar pop-over panel.
struct GumballMenuBarCommands: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var status = AppStatusBridge.shared

    var body: some View {
        VStack(spacing: 0) {
            nowPlayingSection
            Divider()
            controlsSection
            Divider()
            statusSection
            Divider()
            actionSection
        }
        .frame(width: 280)
    }

    // MARK: - Now Playing

    private var nowPlayingSection: some View {
        HStack(alignment: .center, spacing: 10) {
            artworkView
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) { loveButton }

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
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                if let artist = status.trackArtist {
                    LastFMMetadataLink(
                        text: artist,
                        url: lastFMArtistURL,
                        role: .artist
                    )
                    .padding(.top, 2)
                }
                if let album = status.trackAlbum {
                    LastFMMetadataLink(
                        text: album,
                        url: lastFMAlbumURL,
                        role: .album
                    )
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }

    @ViewBuilder
    private var loveButton: some View {
        let loved = status.isTrackLoved
        let hasTrack = status.trackTitle != nil
        let isLoading = hasTrack && loved == nil

        Button {
            Task {
                if loved == true {
                    await AppStatusBridge.shared.unloveCurrentTrack?()
                } else {
                    await AppStatusBridge.shared.loveCurrentTrack?()
                }
            }
        } label: {
            Image(systemName: loved == true ? "heart.fill" : "heart")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(loved == true ? Color(red: 213/255, green: 16/255, blue: 7/255) : Color.white)
                .shadow(color: loved == true ? .white.opacity(0.3) : .black.opacity(0.3), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(!hasTrack || isLoading)
        .opacity(!hasTrack || isLoading ? 0.35 : 1)
        .padding(6)
        .help(loved == true ? "Unlove on Last.fm" : "Love on Last.fm")
        .animation(.easeInOut(duration: 0.15), value: loved)
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
            RoundedRectangle(cornerRadius: 6)
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
        HStack(spacing: 32) {
            Button { PlaybackController.previousTrack() } label: {
                Image(systemName: "backward.fill")
            }
            Button { PlaybackController.togglePlayPause() } label: {
                Image(systemName: status.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .font(.system(size: 18))
            Button { PlaybackController.nextTrack() } label: {
                Image(systemName: "forward.fill")
            }
        }
        .font(.system(size: 15))
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .center, spacing: 5) {
            authStatusRow
            if status.pendingCount > 0 {
                Label {
                    Text("\(status.pendingCount) pending scrobble\(status.pendingCount == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var authStatusRow: some View {
        if status.authStatus == .authorized {
            LastFMConnectedRow(url: lastFMProfileURL)
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
        VStack(alignment: .center, spacing: 5) {
            MenuActionRow(title: "Track History", systemImage: "clock.arrow.circlepath") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "queue-debug")
            }
            MenuActionRow(title: "Quit Gumball", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
