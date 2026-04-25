import Foundation
import os

/// Gates scrobble candidates by source.
///
/// For browser sources, applies a three-tier check:
///   1. Artist + title are required (enforced upstream by the state machine).
///   2. Duration ≤ 10 min → eligible immediately (music track fast path).
///   3. Duration > 10 min → `artist.getInfo` playcount ≥ 1 000 → eligible
///      (passes DJ mixes / long album plays from real artists; drops video essays).
///
/// Non-browser sources are trusted (Spotify, Apple Music, etc. don't need URL-level validation).
actor ScrobbleSourceFilter {
    private let log = Logger(subsystem: "com.gumball.Gumball", category: "SourceFilter")
    private let client: LastFMClient
    /// In-memory per-session cache: artist name → is a real music artist on Last.fm.
    private var artistCache: [String: Bool] = [:]

    /// Sources that carry mixed content (music AND podcasts/videos) and therefore need
    /// the duration + artist-validity filter applied.  Pure music apps (Apple Music, Tidal,
    /// Deezer…) are not listed here and are trusted unconditionally.
    private static let mixedContentSources: Set<String> = [
        // Browsers — any website can be playing
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",   // Arc
        "com.microsoft.edgemac",        // Edge
        "com.operasoftware.Opera",
        "com.brave.Browser",
        "com.kagi.kagimacOS",           // Orion
        "com.vivaldi.Vivaldi",
        // Native apps with mixed music + podcast/video content
        "com.spotify.client",           // Spotify: music AND podcasts
    ]

    /// Duration cutoff (seconds) per source bundle ID. Tracks longer than this trigger
    /// an artist.getInfo validity check. Spotify gets a higher threshold to accommodate
    /// classical / ambient tracks while still catching podcasts (which run 30 min+).
    private static let shortTrackCutoff: [String: Double] = [
        "com.spotify.client": 22 * 60,  // 22 minutes
    ]
    private static let defaultShortTrackCutoff: Double = 10 * 60  // 10 minutes

    /// Minimum Last.fm global playcount for an artist to be considered a real music act.
    private static let minArtistPlaycount: Int = 1_000

    init(client: LastFMClient) {
        self.client = client
    }

    func isEligible(_ candidate: ScrobbleStateMachine.ScrobbleCandidate) async -> Bool {
        guard let bundleID = candidate.sourceBundleID,
              Self.mixedContentSources.contains(bundleID) else {
            // Pure music app or unknown source: trust it.
            return true
        }

        // Short track: assume music.
        let cutoff = Self.shortTrackCutoff[bundleID] ?? Self.defaultShortTrackCutoff
        let duration = candidate.duration ?? 0
        if duration <= cutoff {
            return true
        }

        // Long track from a browser: verify the artist exists on Last.fm.
        return await isValidMusicArtist(candidate.artist)
    }

    private func isValidMusicArtist(_ artist: String) async -> Bool {
        if let cached = artistCache[artist] { return cached }

        do {
            let info = try await client.artistGetInfo(artist: artist)
            let valid = info.playcount >= Self.minArtistPlaycount
            log.info("Artist '\(artist, privacy: .public)': playcount=\(info.playcount, privacy: .public) → \(valid ? "eligible" : "filtered", privacy: .public)")
            artistCache[artist] = valid
            return valid
        } catch LastFMError.apiError(code: 6, message: _) {
            // Artist not found on Last.fm.
            log.info("Artist '\(artist, privacy: .public)' not found on Last.fm → filtered")
            artistCache[artist] = false
            return false
        } catch {
            // Network error etc.: be conservative and drop long-form browser content.
            log.notice("Artist check failed for '\(artist, privacy: .public)': \(String(describing: error), privacy: .public) → filtered")
            return false
        }
    }
}
