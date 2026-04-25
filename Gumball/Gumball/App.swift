import SwiftUI
import os

@main
struct GumballApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Scrobble queue (debug)", id: "queue-debug") {
            DebugQueueView()
        }
        .defaultSize(width: 920, height: 480)

        MenuBarExtra("Gumball", systemImage: "opticaldisc") {
            GumballMenuBarCommands()
        }

        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var watcher: NowPlayingWatcher?
    private var task: Task<Void, Never>?
    private var housekeepingTask: Task<Void, Never>?
    private var lastfmTask: Task<Void, Never>?
    private var flushLoopTask: Task<Void, Never>?

    private let log = Logger(subsystem: "com.gumball.Gumball", category: "App")
    private let scrobbleSM = ScrobbleStateMachine()
    private var queue: ScrobbleQueue?
    private var scrobbleFlusher: ScrobbleFlushService?
    private var lastfmConfig: LastFMConfig?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let watcher = NowPlayingWatcher()
        self.watcher = watcher

        if let rawAPIKey = ProcessInfo.processInfo.environment["LASTFM_API_KEY"],
           let rawSecret = ProcessInfo.processInfo.environment["LASTFM_SHARED_SECRET"],
           let apiKey = Self.cleanedEnvCredential(rawAPIKey),
           let secret = Self.cleanedEnvCredential(rawSecret),
           !apiKey.isEmpty, !secret.isEmpty
        {
            Task { @MainActor in
                AppStatusBridge.shared.authStatus = .authorizing
            }
            let config = LastFMConfig(apiKey: apiKey, sharedSecret: secret)
            self.lastfmConfig = config
            self.scrobbleFlusher = ScrobbleFlushService(
                config: config,
                onSessionInvalid: { [weak self] in
                    self?.log.notice("Last.fm session cleared; re-running desktop auth")
                    self?.startLastFMAuth()
                }
            )
            startLastFMAuth()
        } else {
            Task { @MainActor in
                AppStatusBridge.shared.authStatus = .notConfigured
            }
            log.info("Last.fm creds not set; skipping auth + scrobble send (set LASTFM_API_KEY + LASTFM_SHARED_SECRET)")
        }

        task = Task { [weak watcher, weak self] in
            guard let watcher, let self else { return }
            do {
                let q = try await ScrobbleQueue()
                self.queue = q
                let pending = (try? await q.countPending()) ?? -1
                self.log.info("ScrobbleQueue ready (pending=\(pending, privacy: .public))")
                await MainActor.run {
                    QueueDebugBridge.shared.attachQueue(q)
                }
                await QueueDebugBridge.shared.refresh()
            } catch {
                self.log.error("ScrobbleQueue init failed: \(String(describing: error), privacy: .public)")
            }

            self.startFlushLoopIfNeeded()

            for await event in watcher.events() {
                log.info("NowPlaying: playing=\(event.playing, privacy: .public) title=\(event.title ?? "-", privacy: .public) artist=\(event.artist ?? "-", privacy: .public) album=\(event.album ?? "-", privacy: .public) dur=\(event.duration ?? -1, privacy: .public) elapsed=\(event.elapsedTime ?? -1, privacy: .public)")
                await MainActor.run {
                    AppStatusBridge.shared.currentTrack = Self.displayTrack(event)
                }

                let outputs = await self.scrobbleSM.process(event)
                for output in outputs {
                    switch output {
                    case .nowPlaying(let ping):
                        log.info("SM nowPlaying: \(ping.artist, privacy: .public) — \(ping.track, privacy: .public)")
                        await self.updateNowPlaying(ping)
                    case .scrobbleCandidate(let scrobble):
                        log.info("SM scrobbleCandidate: played=\(scrobble.playedSeconds, privacy: .public)s dur=\(scrobble.duration ?? -1, privacy: .public)s \(scrobble.artist, privacy: .public) — \(scrobble.track, privacy: .public)")
                        await self.enqueueScrobble(scrobble)
                    }
                }
            }
        }

        housekeepingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
                guard let self else { return }
                let outputs = await self.scrobbleSM.housekeeping()
                for output in outputs {
                    switch output {
                    case .nowPlaying:
                        break
                    case .scrobbleCandidate(let scrobble):
                        self.log.info("SM scrobbleCandidate (idle-close): played=\(scrobble.playedSeconds, privacy: .public)s dur=\(scrobble.duration ?? -1, privacy: .public)s \(scrobble.artist, privacy: .public) — \(scrobble.track, privacy: .public)")
                        await self.enqueueScrobble(scrobble)
                    }
                }
            }
        }
    }

    private func startLastFMAuth() {
        lastfmTask?.cancel()
        guard let lastfmConfig else { return }
        let auth = LastFMAuthCoordinator(config: lastfmConfig)
        Task { @MainActor in
            AppStatusBridge.shared.authStatus = .authorizing
        }
        lastfmTask = Task { [weak self] in
            do {
                _ = try await auth.ensureSession(interactive: true)
                await MainActor.run {
                    AppStatusBridge.shared.authStatus = .authorized
                }
                self?.log.info("Last.fm auth OK")
                await self?.triggerFlush()
            } catch {
                await MainActor.run {
                    AppStatusBridge.shared.authStatus = .failed
                }
                self?.log.error("Last.fm auth failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func startFlushLoopIfNeeded() {
        flushLoopTask?.cancel()
        guard scrobbleFlusher != nil else { return }
        flushLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                await self?.triggerFlush()
            }
        }
    }

    private func triggerFlush() async {
        guard let flusher = scrobbleFlusher, let queue = queue else { return }
        await flusher.flushIfPossible(queue: queue)
        await QueueDebugBridge.shared.refresh()
    }

    private func updateNowPlaying(_ ping: ScrobbleStateMachine.NowPlayingPing) async {
        guard let scrobbleFlusher else { return }
        await scrobbleFlusher.updateNowPlaying(ping)
    }

    private func enqueueScrobble(_ scrobble: ScrobbleStateMachine.ScrobbleCandidate) async {
        guard let queue else { return }
        do {
            _ = try await queue.enqueue(scrobble)
            await QueueDebugBridge.shared.refresh()
        } catch {
            log.error("enqueue failed: \(String(describing: error), privacy: .public)")
            return
        }
        await triggerFlush()
        await QueueDebugBridge.shared.refresh()
    }

    private static func cleanedEnvCredential(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func displayTrack(_ event: NowPlayingEvent) -> String {
        guard event.playing else { return "Paused" }
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = event.artist?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (artist?.isEmpty == false ? artist : nil, title?.isEmpty == false ? title : nil) {
        case let (artist?, title?):
            return "\(artist) — \(title)"
        case let (nil, title?):
            return title
        default:
            return "Playing"
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Thread.isMainThread {
            QueueDebugBridge.shared.detachQueue()
        } else {
            DispatchQueue.main.sync {
                QueueDebugBridge.shared.detachQueue()
            }
        }
        task?.cancel()
        task = nil
        lastfmTask?.cancel()
        lastfmTask = nil
        flushLoopTask?.cancel()
        flushLoopTask = nil
        housekeepingTask?.cancel()
        housekeepingTask = nil
        watcher?.stop()
        watcher = nil
    }
}
