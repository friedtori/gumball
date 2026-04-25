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

/// Temporary debug window: live-ish view of `scrobble_queue` rows.
struct DebugQueueView: View {
    @ObservedObject private var bridge = QueueDebugBridge.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scrobble queue (debug)")
                    .font(.headline)
                Spacer()
                Button("Refresh") {
                    Task { await bridge.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            Text("SQLite: ~/Library/Application Support/Gumball/gumball.sqlite3")
                .font(.caption)
                .foregroundStyle(.secondary)

            Table(bridge.rows) {
                TableColumn("id") { Text("\($0.id)") }
                    .width(min: 36, ideal: 44)
                TableColumn("status") { Text($0.status) }
                    .width(min: 70, ideal: 90)
                TableColumn("artist") { Text($0.artist).lineLimit(1) }
                TableColumn("track") { Text($0.track).lineLimit(1) }
                TableColumn("album") { Text($0.album ?? "—").lineLimit(1) }
                TableColumn("dur") {
                    Text($0.duration.map { String(format: "%.0f", $0) } ?? "—")
                }
                .width(min: 40, ideal: 48)
                TableColumn("started") {
                    Text($0.startedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .width(min: 120, ideal: 140)
                TableColumn("played") {
                    Text(String(format: "%.0fs", $0.playedSeconds))
                }
                .width(min: 52, ideal: 60)
                TableColumn("att") {
                    Text("\($0.attempts)")
                }
                .width(min: 32, ideal: 36)
                TableColumn("last error") {
                    Text($0.lastError ?? "—")
                        .font(.caption)
                        .lineLimit(2)
                }
            }
        }
        .padding()
        .frame(minWidth: 880, minHeight: 360)
        .task {
            await bridge.refresh()
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            Task { await bridge.refresh() }
        }
    }
}

/// Last.fm favicon: red rounded rect with white "fm" text.
private struct LastFMBadge: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: 0.835, green: 0.063, blue: 0.027))
                .frame(width: 18, height: 12)
            Text("fm")
                .font(.system(size: 7.5, weight: .black))
                .foregroundStyle(.white)
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
        HStack(alignment: .top, spacing: 10) {
            artworkView
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                if let title = status.trackTitle {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(status.isPlaying ? "Playing" : "Nothing playing")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                if let artist = status.trackArtist {
                    Text(artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let album = status.trackAlbum {
                    Text(album)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
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
        VStack(alignment: .leading, spacing: 5) {
            authStatusRow
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var authStatusRow: some View {
        if status.authStatus == .authorized, let username = status.lastFMUsername {
            Button {
                if let url = URL(string: "https://www.last.fm/user/\(username)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label {
                    Text("Last.fm connected")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } icon: {
                    LastFMBadge()
                }
            }
            .buttonStyle(.plain)
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
        VStack(spacing: 0) {
            Button("Show queue debug…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "queue-debug")
            }
            Button("Refresh queue list") {
                Task { await QueueDebugBridge.shared.refresh() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Quit Gumball") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
