import Foundation

/// Normalized event emitted by `NowPlayingWatcher`.
struct NowPlayingEvent: Equatable, Sendable {
    var bundleIdentifier: String?
    var parentApplicationBundleIdentifier: String?

    var playing: Bool

    var title: String?
    var artist: String?
    var album: String?

    /// Seconds.
    var duration: Double?

    /// Seconds.
    var elapsedTime: Double?

    /// Timestamp for this snapshot, if provided by the adapter.
    var timestamp: Date?

    /// Decoded artwork image bytes, if the adapter provided them.
    var artworkData: Data?
}

extension NowPlayingEvent {
    /// Adapter payload shape (selected fields). We keep this separate so we can evolve normalization without
    /// leaking adapter field names throughout the codebase.
    struct AdapterPayload: Decodable, Sendable {
        var bundleIdentifier: String?
        var parentApplicationBundleIdentifier: String?

        var playing: Bool?

        var title: String?
        var artist: String?
        var album: String?

        var duration: Double?
        var elapsedTime: Double?

        var timestamp: TimestampValue?

        /// Base64-encoded image bytes from the adapter.
        var artworkData: String?
        var artworkMimeType: String?

        struct TimestampValue: Decodable, Sendable {
            var date: Date?

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()

                if let unix = try? container.decode(Double.self) {
                    // Heuristic: adapter may emit either seconds or milliseconds.
                    let seconds = unix > 10_000_000_000 ? (unix / 1000.0) : unix
                    self.date = Date(timeIntervalSince1970: seconds)
                    return
                }

                if let str = try? container.decode(String.self) {
                    // Try ISO-8601 first, then fall back to Date's formatter heuristics via parsing not supported.
                    let iso = ISO8601DateFormatter()
                    if let d = iso.date(from: str) {
                        self.date = d
                    } else {
                        self.date = nil
                    }
                    return
                }

                self.date = nil
            }
        }
    }

    init(adapter payload: AdapterPayload) {
        self.bundleIdentifier = payload.bundleIdentifier
        self.parentApplicationBundleIdentifier = payload.parentApplicationBundleIdentifier

        self.playing = payload.playing ?? false

        self.title = payload.title
        self.artist = payload.artist
        self.album = payload.album

        self.duration = payload.duration
        self.elapsedTime = payload.elapsedTime
        self.timestamp = payload.timestamp?.date
        self.artworkData = payload.artworkData.flatMap {
            Data(base64Encoded: $0, options: .ignoreUnknownCharacters)
        }
    }

    func merging(adapter payload: AdapterPayload) -> NowPlayingEvent {
        NowPlayingEvent(
            bundleIdentifier: payload.bundleIdentifier ?? bundleIdentifier,
            parentApplicationBundleIdentifier: payload.parentApplicationBundleIdentifier ?? parentApplicationBundleIdentifier,
            playing: payload.playing ?? playing,
            title: payload.title ?? title,
            artist: payload.artist ?? artist,
            album: payload.album ?? album,
            duration: payload.duration ?? duration,
            elapsedTime: payload.elapsedTime ?? elapsedTime,
            timestamp: payload.timestamp?.date ?? timestamp,
            artworkData: payload.artworkData.flatMap {
                Data(base64Encoded: $0, options: .ignoreUnknownCharacters)
            } ?? artworkData
        )
    }
}

