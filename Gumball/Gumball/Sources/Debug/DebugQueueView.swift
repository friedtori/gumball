import SwiftUI
import AppKit

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

/// Menu bar commands that need `openWindow` from the environment.
struct GumballMenuBarCommands: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var status = AppStatusBridge.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(status.currentTrack)
                .lineLimit(2)
            Text("Last.fm: \(status.authStatus.rawValue)")
                .foregroundStyle(.secondary)
            Text("Pending queue: \(status.pendingCount)")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)

        Divider()

        Button("Show queue debug…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "queue-debug")
        }
        Divider()
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
