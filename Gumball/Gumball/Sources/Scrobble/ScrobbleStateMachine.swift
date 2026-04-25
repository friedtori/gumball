import Foundation
import os

/// In-memory state machine that turns `NowPlayingEvent` updates into:
/// - best-effort "now playing" pings (not persisted)
/// - finalized scrobble candidates (not sent/persisted yet)
///
/// Per spec:
/// - Use wall-clock time in `playing=true` state.
/// - Do not rely on position deltas (seeks lie).
actor ScrobbleStateMachine {
    enum Output: Sendable {
        case nowPlaying(NowPlayingPing)
        case scrobbleCandidate(ScrobbleCandidate)
    }

    struct NowPlayingPing: Sendable {
        var artist: String
        var track: String
        var album: String?
        var duration: Double?
        var startedAt: Date
        var sourceBundleID: String?
        var sourceParentBundleID: String?
    }

    struct ScrobbleCandidate: Sendable {
        var artist: String
        var track: String
        var album: String?
        var duration: Double?
        var startedAt: Date
        var playedSeconds: Double
        var sourceBundleID: String?
        var sourceParentBundleID: String?
    }

    private struct TrackKey: Equatable, Sendable {
        var title: String
        var artist: String
        var album: String?
        var durationBucket: Int? // coarse bucketing to reduce spurious churn
        var sourceBundleID: String?
        var sourceParentBundleID: String?
    }

    private struct CurrentPlay: Sendable {
        var key: TrackKey
        var startedAt: Date
        var playedSeconds: Double
        var lastWallClock: Date
        var lastElapsedTime: Double?
        var lastPlaying: Bool
    }

    private let log = Logger(subsystem: "com.gumball.Gumball", category: "ScrobbleSM")
    private var current: CurrentPlay?
    private let idleCloseSeconds: TimeInterval = 60
    private let idleClosePlayingEligibleSeconds: TimeInterval = 180

    init() {}

    /// Call periodically (or on app background) to close out plays that stop producing updates.
    func housekeeping(now: Date = Date()) -> [Output] {
        guard let cur = current else { return [] }

        let idle = now.timeIntervalSince(cur.lastWallClock)
        if cur.lastPlaying == false {
            guard idle >= idleCloseSeconds else { return [] }
            return finalizeCurrent(at: now, closingReason: "idle-timeout-paused") ?? []
        }

        // If we were "playing" but went silent, only close after a longer timeout AND only if the play
        // is already scrobble-eligible. This avoids inventing ends for ineligible plays while still
        // preventing eligible plays from getting stranded indefinitely.
        guard idle >= idleClosePlayingEligibleSeconds else { return [] }
        guard isScrobbleEligible(duration: curDurationSeconds(from: cur.key), playedSeconds: cur.playedSeconds) else { return [] }

        return finalizeCurrent(at: now, closingReason: "idle-timeout-playing-eligible") ?? []
    }

    func process(_ event: NowPlayingEvent) -> [Output] {
        let now = event.timestamp ?? Date()

        // If we don't have the minimum identity fields, we can't track a play.
        guard
            let title = normalizedNonEmpty(event.title),
            let artist = normalizedNonEmpty(event.artist)
        else {
            // If metadata disappears mid-play, close out current (best effort).
            if let finished = finalizeIfNeeded(at: now, closingReason: "missing-metadata") {
                return finished
            }
            return []
        }

        let key = TrackKey(
            title: title,
            artist: artist,
            album: normalizedOptional(event.album),
            durationBucket: bucketDuration(event.duration),
            sourceBundleID: event.bundleIdentifier,
            sourceParentBundleID: event.parentApplicationBundleIdentifier
        )

        var outputs: [Output] = []

        if current == nil {
            current = CurrentPlay(
                key: key,
                startedAt: now,
                playedSeconds: 0,
                lastWallClock: now,
                lastElapsedTime: event.elapsedTime,
                lastPlaying: event.playing
            )
            outputs.append(.nowPlaying(makeNowPlayingPing(from: key, startedAt: now, duration: event.duration)))
            log.debug("Open play: \(artist, privacy: .public) — \(title, privacy: .public)")
            return outputs
        }

        // Update accumulated play time for the existing play before we possibly switch tracks.
        accumulatePlayedTime(now: now, newPlaying: event.playing)

        // Detect track boundary (metadata change or "replay" heuristic).
        if let currentKey = current?.key, isNewTrack(newKey: key, oldKey: currentKey, newElapsed: event.elapsedTime) {
            if let finalized = finalizeCurrent(at: now, closingReason: "track-change") {
                outputs.append(contentsOf: finalized)
            }

            current = CurrentPlay(
                key: key,
                startedAt: now,
                playedSeconds: 0,
                lastWallClock: now,
                lastElapsedTime: event.elapsedTime,
                lastPlaying: event.playing
            )
            outputs.append(.nowPlaying(makeNowPlayingPing(from: key, startedAt: now, duration: event.duration)))
            log.debug("Open play: \(artist, privacy: .public) — \(title, privacy: .public)")
            return outputs
        }

        // Same track; update trackers.
        if var cur = current {
            cur.lastElapsedTime = event.elapsedTime
            cur.lastPlaying = event.playing
            cur.lastWallClock = now
            current = cur
        }

        return outputs
    }

    // MARK: - Accumulation / boundary detection

    private func accumulatePlayedTime(now: Date, newPlaying: Bool) {
        guard var cur = current else { return }

        if cur.lastPlaying, newPlaying {
            let delta = max(0, now.timeIntervalSince(cur.lastWallClock))
            cur.playedSeconds += delta
        }

        cur.lastWallClock = now
        cur.lastPlaying = newPlaying
        current = cur
    }

    /// Returns true if `newKey` should start a new play relative to `oldKey`.
    private func isNewTrack(newKey: TrackKey, oldKey: TrackKey, newElapsed: Double?) -> Bool {
        if newKey != oldKey { return true }

        // Replay heuristic: same metadata, but elapsed time jumps backwards substantially
        // (e.g. track restarted). We keep this conservative to avoid false positives on seeks.
        guard
            let prev = current?.lastElapsedTime,
            let next = newElapsed
        else { return false }

        // If we were well into the track and suddenly we're near the beginning, treat as replay.
        if prev > 30, next < 5 {
            return true
        }

        return false
    }

    // MARK: - Finalization

    private func finalizeIfNeeded(at now: Date, closingReason: String) -> [Output]? {
        guard current != nil else { return nil }
        return finalizeCurrent(at: now, closingReason: closingReason)
    }

    private func finalizeCurrent(at now: Date, closingReason: String) -> [Output]? {
        guard let cur = current else { return nil }

        // Add any final wall-clock delta if we were playing right up to now.
        var tmp = cur
        if tmp.lastPlaying {
            let delta = max(0, now.timeIntervalSince(tmp.lastWallClock))
            tmp.playedSeconds += delta
        }

        current = nil

        let duration = curDurationSeconds(from: tmp.key)
        let played = tmp.playedSeconds

        log.debug("Close play (\(closingReason, privacy: .public)): played=\(played, privacy: .public)s title=\(tmp.key.title, privacy: .public)")

        guard isScrobbleEligible(duration: duration, playedSeconds: played) else {
            return []
        }

        let candidate = ScrobbleCandidate(
            artist: tmp.key.artist,
            track: tmp.key.title,
            album: tmp.key.album,
            duration: duration,
            startedAt: tmp.startedAt,
            playedSeconds: played,
            sourceBundleID: tmp.key.sourceBundleID,
            sourceParentBundleID: tmp.key.sourceParentBundleID
        )
        return [.scrobbleCandidate(candidate)]
    }

    // MARK: - Helpers

    private func makeNowPlayingPing(from key: TrackKey, startedAt: Date, duration: Double?) -> NowPlayingPing {
        NowPlayingPing(
            artist: key.artist,
            track: key.title,
            album: key.album,
            duration: duration,
            startedAt: startedAt,
            sourceBundleID: key.sourceBundleID,
            sourceParentBundleID: key.sourceParentBundleID
        )
    }

    private func normalizedNonEmpty(_ s: String?) -> String? {
        let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private func normalizedOptional(_ s: String?) -> String? {
        normalizedNonEmpty(s)
    }

    private func bucketDuration(_ seconds: Double?) -> Int? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        // Round to nearest second; bucket reduces churn due to float noise.
        return Int((seconds).rounded())
    }

    private func curDurationSeconds(from key: TrackKey) -> Double? {
        guard let bucket = key.durationBucket else { return nil }
        return Double(bucket)
    }

    private func isScrobbleEligible(duration: Double?, playedSeconds: Double) -> Bool {
        if let duration {
            guard duration > 30 else { return false }
            return (playedSeconds >= duration / 2.0) || (playedSeconds >= 240)
        } else {
            // Unknown duration: fall back to the "4 minute" rule only.
            return playedSeconds >= 240
        }
    }
}

