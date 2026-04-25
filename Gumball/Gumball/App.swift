import SwiftUI
import os

@main
struct GumballApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // MVP: no UI yet. Keep an empty Settings scene so the app can run.
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var watcher: NowPlayingWatcher?
    private var task: Task<Void, Never>?
    private var housekeepingTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.gumball.Gumball", category: "App")
    private let scrobbleSM = ScrobbleStateMachine()
    private var queue: ScrobbleQueue?
    private var lastfmTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar app (no Dock icon) behavior.
        NSApp.setActivationPolicy(.accessory)

        let watcher = NowPlayingWatcher()
        self.watcher = watcher

        // Last.fm desktop auth (console-driven). Provide credentials via environment variables:
        // - LASTFM_API_KEY
        // - LASTFM_SHARED_SECRET
        if let apiKey = ProcessInfo.processInfo.environment["LASTFM_API_KEY"],
           let secret = ProcessInfo.processInfo.environment["LASTFM_SHARED_SECRET"],
           !apiKey.isEmpty, !secret.isEmpty
        {
            let auth = LastFMAuthCoordinator(config: .init(apiKey: apiKey, sharedSecret: secret))
            lastfmTask = Task {
                do {
                    _ = try await auth.ensureSession(interactive: true)
                    log.info("Last.fm auth OK")
                } catch {
                    log.error("Last.fm auth failed: \(String(describing: error), privacy: .public)")
                }
            }
        } else {
            log.info("Last.fm creds not set; skipping auth (set LASTFM_API_KEY + LASTFM_SHARED_SECRET)")
        }

        task = Task { [weak watcher] in
            guard let watcher else { return }

            do {
                self.queue = try await ScrobbleQueue()
                if let queue = self.queue {
                    let pending = (try? await queue.countPending()) ?? -1
                    self.log.info("ScrobbleQueue ready (pending=\(pending, privacy: .public))")
                } else {
                    self.log.info("ScrobbleQueue ready")
                }
            } catch {
                self.log.error("ScrobbleQueue init failed: \(String(describing: error), privacy: .public)")
            }
            for await event in watcher.events() {
                log.info("NowPlaying: playing=\(event.playing, privacy: .public) title=\(event.title ?? "-", privacy: .public) artist=\(event.artist ?? "-", privacy: .public) album=\(event.album ?? "-", privacy: .public) dur=\(event.duration ?? -1, privacy: .public) elapsed=\(event.elapsedTime ?? -1, privacy: .public)")

                let outputs = await self.scrobbleSM.process(event)
                for output in outputs {
                    switch output {
                    case .nowPlaying(let ping):
                        log.info("SM nowPlaying: \(ping.artist, privacy: .public) — \(ping.track, privacy: .public)")
                    case .scrobbleCandidate(let scrobble):
                        log.info("SM scrobbleCandidate: played=\(scrobble.playedSeconds, privacy: .public)s dur=\(scrobble.duration ?? -1, privacy: .public)s \(scrobble.artist, privacy: .public) — \(scrobble.track, privacy: .public)")
                        if let queue = self.queue {
                            do {
                                _ = try await queue.enqueue(scrobble)
                            } catch {
                                log.error("enqueue failed: \(String(describing: error), privacy: .public)")
                            }
                        }
                    }
                }
            }
        }

        housekeepingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
                let outputs = await self.scrobbleSM.housekeeping()
                for output in outputs {
                    switch output {
                    case .nowPlaying:
                        break
                    case .scrobbleCandidate(let scrobble):
                        log.info("SM scrobbleCandidate (idle-close): played=\(scrobble.playedSeconds, privacy: .public)s dur=\(scrobble.duration ?? -1, privacy: .public)s \(scrobble.artist, privacy: .public) — \(scrobble.track, privacy: .public)")
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        task?.cancel()
        task = nil
        lastfmTask?.cancel()
        lastfmTask = nil
        housekeepingTask?.cancel()
        housekeepingTask = nil
        watcher?.stop()
        watcher = nil
    }
}

