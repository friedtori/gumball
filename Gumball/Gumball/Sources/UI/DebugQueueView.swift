import SwiftUI
import AppKit

struct OptionsWindowView: View {
    var body: some View {
        TabView {
            BackgroundOptionsView()
                .tabItem {
                    Label("Options", systemImage: "slider.horizontal.3")
                }

            DebugQueueView()
                .tabItem {
                    Label("Track History", systemImage: "clock.arrow.circlepath")
                }
        }
        .padding()
        .frame(minWidth: 880, minHeight: 420)
    }
}

private struct BackgroundOptionsView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @AppStorage(GumballOptionKeys.backgroundStyle) private var backgroundStyle = MenuBarBackgroundStyle.slitScan.rawValue
    @AppStorage(GumballOptionKeys.backgroundScrollDuration) private var backgroundScrollDuration = 30.0
    @AppStorage(GumballOptionKeys.keepPinnedPopoverVisible) private var keepPinnedPopoverVisible = false

    var body: some View {
        Form {
            Section {
                Picker("Background style", selection: $backgroundStyle) {
                    ForEach(MenuBarBackgroundStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Background scroll speed", selection: $backgroundScrollDuration) {
                    Text("Static").tag(0.0)
                    Text("Slow").tag(30.0)
                    Text("Medium").tag(20.0)
                    Text("Fast").tag(8.0)
                }
                .pickerStyle(.segmented)

                Text(backgroundScrollDuration > 0 ? "Scroll duration: \(backgroundScrollDuration.formatted(.number.precision(.fractionLength(0))))s" : "Scroll disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label("Fast scroll speeds may consume more CPU/GPU resources.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Album Art Background")
            } footer: {
                Text("Choose between a blurred album-art background, the current slit-scan treatment, or no album-art background.")
            }

            Section {
                Toggle("Keep popover visible for debugging", isOn: $keepPinnedPopoverVisible)
            } footer: {
                Text("Opens a regular debug window that renders the same popover content. The real menu bar popover is still controlled by macOS and will dismiss normally.")
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(maxWidth: 520, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            syncPinnedPopoverWindow()
        }
        .onChange(of: keepPinnedPopoverVisible) {
            syncPinnedPopoverWindow()
        }
    }

    private func syncPinnedPopoverWindow() {
        if keepPinnedPopoverVisible {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "popover-debug")
        } else {
            dismissWindow(id: "popover-debug")
        }
    }
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
