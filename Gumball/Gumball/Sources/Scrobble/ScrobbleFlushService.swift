import Foundation
import os

/// Drains `ScrobbleQueue` in batches of up to 50 via `track.scrobble`.
/// Retry policy: 11, 16 → `incrementAttempts`. 9 → clears session key, increments attempts, then `onSessionInvalid` (e.g. re-run desktop auth). Other → permanent fail.
actor ScrobbleFlushService {
    private let log = Logger(subsystem: "com.gumball.Gumball", category: "ScrobbleFlush")
    private let config: LastFMConfig
    private let client: LastFMClient
    private let onSessionInvalid: @Sendable () -> Void

    var maxRetryAttempts: Int = 8

    init(
        config: LastFMConfig,
        onSessionInvalid: @escaping @Sendable () -> Void = {}
    ) {
        self.config = config
        self.client = LastFMClient(config: config)
        self.onSessionInvalid = onSessionInvalid
    }

    /// Fetches at most 50 pending rows, POSTs one batch, updates queue status.
    func flushIfPossible(queue: ScrobbleQueue) async {
        do {
            let sessionKey: String? = try Keychain.getString(
                service: config.keychainService,
                account: config.keychainAccount
            )
            guard let sk = sessionKey, !sk.isEmpty else { return }

            let rows = try await queue.fetchPending(limit: 50)
            guard !rows.isEmpty else { return }

            let items: [LastFMBatchScrobbleItem] = rows.map {
                LastFMBatchScrobbleItem(
                    artist: $0.artist,
                    track: $0.track,
                    album: $0.album,
                    duration: $0.duration,
                    startedAt: $0.startedAt
                )
            }

            do {
                try await client.trackScrobbleBatch(items: items, sessionKey: sk)
                for r in rows {
                    try await queue.markSent(id: r.id)
                }
                log.info("Scrobbled batch (count=\(rows.count, privacy: .public))")
            } catch {
                if case let LastFMError.apiError(code, message) = error {
                    await handleAPIError(
                        code: code,
                        message: message,
                        queue: queue,
                        rows: rows
                    )
                } else {
                    for r in rows {
                        if r.attempts + 1 >= maxRetryAttempts {
                            try? await queue.markPermanentlyFailed(
                                id: r.id,
                                lastError: String(describing: error)
                            )
                        } else {
                            try? await queue.incrementAttempts(
                                id: r.id,
                                lastError: String(describing: error)
                            )
                        }
                    }
                    log.error("Scrobble batch failed: \(String(describing: error), privacy: .public)")
                }
            }
        } catch {
            log.error("flushIfPossible: \(String(describing: error), privacy: .public)")
        }
    }

    /// Best-effort Last.fm now-playing ping. Not queued; failures are logged only.
    func updateNowPlaying(_ ping: ScrobbleStateMachine.NowPlayingPing) async {
        do {
            let sessionKey: String? = try Keychain.getString(
                service: config.keychainService,
                account: config.keychainAccount
            )
            guard let sk = sessionKey, !sk.isEmpty else { return }

            try await client.trackUpdateNowPlaying(
                item: LastFMNowPlayingItem(
                    artist: ping.artist,
                    track: ping.track,
                    album: ping.album,
                    duration: ping.duration
                ),
                sessionKey: sk
            )
            log.info("Updated now playing: \(ping.artist, privacy: .public) — \(ping.track, privacy: .public)")
        } catch {
            if case let LastFMError.apiError(code, message) = error {
                switch code {
                case 9:
                    log.error("Last.fm now-playing invalid session (9); re-auth required: \(message, privacy: .public)")
                    try? Keychain.delete(
                        service: config.keychainService,
                        account: config.keychainAccount
                    )
                    onSessionInvalid()
                case 11, 16:
                    log.notice("Last.fm now-playing temporary failure \(code, privacy: .public): \(message, privacy: .public)")
                default:
                    log.error("Last.fm now-playing failed \(code, privacy: .public): \(message, privacy: .public)")
                }
            } else {
                log.error("Last.fm now-playing failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func handleAPIError(
        code: Int,
        message: String,
        queue: ScrobbleQueue,
        rows: [ScrobbleQueue.Row]
    ) async {
        switch code {
        case 9: // invalid session
            log.error("Last.fm: invalid session (9); re-auth required: \(message, privacy: .public)")
            try? Keychain.delete(
                service: config.keychainService,
                account: config.keychainAccount
            )
            onSessionInvalid()
            for r in rows {
                if r.attempts + 1 >= maxRetryAttempts {
                    try? await queue.markPermanentlyFailed(
                        id: r.id,
                        lastError: "reauth: \(message)"
                    )
                } else {
                    try? await queue.incrementAttempts(
                        id: r.id,
                        lastError: "api(9) \(message)"
                    )
                }
            }
        case 11, 16: // service offline, temporary error — retry
            for r in rows {
                if r.attempts + 1 >= maxRetryAttempts {
                    try? await queue.markPermanentlyFailed(
                        id: r.id,
                        lastError: "api(\(code)) \(message)"
                    )
                } else {
                    try? await queue.incrementAttempts(
                        id: r.id,
                        lastError: "api(\(code)) \(message)"
                    )
                }
            }
            log.notice("Last.fm temporary failure \(code, privacy: .public); will retry: \(message, privacy: .public)")
        default:
            for r in rows {
                try? await queue.markPermanentlyFailed(
                    id: r.id,
                    lastError: "api(\(code)) \(message)"
                )
            }
            log.error("Last.fm scrobble failed \(code, privacy: .public): \(message, privacy: .public)")
        }
    }
}
