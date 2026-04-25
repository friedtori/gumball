import Foundation
import os

/// Watches system Now Playing by registering directly with MediaRemote.framework.
/// Fully event-driven — no subprocess, no polling, no App Nap side-effects.
final class MediaRemoteWatcher: NowPlayingSource, @unchecked Sendable {
    private let log = Logger(subsystem: "com.gumball.Gumball", category: "NowPlaying")

    private var continuation: AsyncStream<NowPlayingEvent>.Continuation?
    private var observers: [NSObjectProtocol] = []
    private var lastEmitted: NowPlayingEvent?
    private var cachedBundleID: String?

    // MARK: - MediaRemote function pointer types

    private typealias RegisterFunc = @convention(c) (DispatchQueue) -> Void
    private typealias GetInfoFunc = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias GetBundleIDFunc = @convention(c) (DispatchQueue, @escaping (String?) -> Void) -> Void

    private let mrRegister: RegisterFunc?
    private let mrGetInfo: GetInfoFunc?
    private let mrGetBundleID: GetBundleIDFunc?

    init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW
        )
        mrRegister = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications")
            .map { unsafeBitCast($0, to: RegisterFunc.self) }
        mrGetInfo = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo")
            .map { unsafeBitCast($0, to: GetInfoFunc.self) }
        mrGetBundleID = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationBundleIdentifier")
            .map { unsafeBitCast($0, to: GetBundleIDFunc.self) }
    }

    func events() -> AsyncStream<NowPlayingEvent> {
        AsyncStream { [weak self] continuation in
            guard let self else { continuation.finish(); return }
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in self?.stop() }
            self.arm()
        }
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Private

    private func arm() {
        guard let mrRegister else {
            log.error("MediaRemote.framework unavailable — cannot watch Now Playing")
            continuation?.finish()
            return
        }

        mrRegister(.main)

        let nc = NotificationCenter.default

        for name in [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationPlaybackStateDidChangeNotification",
        ] {
            observers.append(
                nc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                    self?.fetchAndEmit()
                }
            )
        }

        // App changes: refresh bundle ID first, then info
        observers.append(
            nc.addObserver(
                forName: .init("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.fetchBundleIDThenInfo()
            }
        )

        fetchBundleIDThenInfo()
    }

    private func fetchBundleIDThenInfo() {
        guard let mrGetBundleID else { fetchAndEmit(); return }
        mrGetBundleID(.main) { [weak self] id in
            self?.cachedBundleID = id
            self?.fetchAndEmit()
        }
    }

    private func fetchAndEmit() {
        guard let mrGetInfo else { return }
        mrGetInfo(.main) { [weak self] info in
            guard let self else { return }
            let event = NowPlayingEvent(mediaRemoteInfo: info, bundleIdentifier: cachedBundleID)
            guard event != lastEmitted else { return }
            lastEmitted = event
            continuation?.yield(event)
        }
    }
}

// MARK: - NowPlayingEvent init from MediaRemote info dict

extension NowPlayingEvent {
    init(mediaRemoteInfo info: [String: Any], bundleIdentifier: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.parentApplicationBundleIdentifier = nil

        let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
        self.playing = rate > 0

        self.title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String
        self.artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String
        self.album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String
        self.duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double
        self.elapsedTime = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double
        self.timestamp = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date
    }
}
