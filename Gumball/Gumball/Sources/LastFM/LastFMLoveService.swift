import Foundation
import os

/// Handles track.getInfo (loved state) and track.love / track.unlove.
/// Reads session key and username from UserDefaults — same source as the rest of the app.
actor LastFMLoveService {
    private let log = Logger(subsystem: "com.gumball.Gumball", category: "LoveService")
    private let client: LastFMClient

    init(config: LastFMConfig) {
        self.client = LastFMClient(config: config)
    }

    private var sessionKey: String? { UserDefaults.standard.string(forKey: "lastfm.sessionKey") }
    private var username: String? { UserDefaults.standard.string(forKey: "lastfm.username") }

    /// Fetches the loved state for a track. Returns nil if the username is unavailable
    /// or the network call fails — callers should treat nil as "unknown".
    func fetchLovedState(artist: String, track: String) async -> Bool? {
        guard let username else { return nil }
        do {
            return try await client.trackGetInfo(artist: artist, track: track, username: username)
        } catch {
            log.notice("track.getInfo failed for '\(track, privacy: .public)': \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func love(artist: String, track: String) async {
        guard let sk = sessionKey else {
            log.notice("track.love skipped: no session key")
            return
        }
        do {
            try await client.trackLove(artist: artist, track: track, sessionKey: sk)
            log.info("Loved: \(artist, privacy: .public) — \(track, privacy: .public)")
        } catch {
            log.error("track.love failed: \(String(describing: error), privacy: .public)")
        }
    }

    func unlove(artist: String, track: String) async {
        guard let sk = sessionKey else {
            log.notice("track.unlove skipped: no session key")
            return
        }
        do {
            try await client.trackUnlove(artist: artist, track: track, sessionKey: sk)
            log.info("Unloved: \(artist, privacy: .public) — \(track, privacy: .public)")
        } catch {
            log.error("track.unlove failed: \(String(describing: error), privacy: .public)")
        }
    }
}
