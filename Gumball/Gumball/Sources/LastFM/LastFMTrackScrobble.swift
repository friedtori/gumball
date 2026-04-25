import Foundation

/// Batched `track.scrobble` (POST) with array-style params. Signing uses plain ASCII key sort
/// so `artist[10]` orders before `artist[2]`, as Last.fm requires.
struct LastFMBatchScrobbleItem: Sendable {
    var artist: String
    var track: String
    var album: String?
    var duration: Double?
    /// Last.fm expects the time playback started (UTC, unix seconds).
    var startedAt: Date
}

struct LastFMNowPlayingItem: Sendable {
    var artist: String
    var track: String
    var album: String?
    var duration: Double?
}

extension LastFMClient {
    /// Best-effort now-playing notification. Last.fm requires POST for this write method.
    func trackUpdateNowPlaying(
        item: LastFMNowPlayingItem,
        sessionKey: String
    ) async throws {
        var params: [String: String] = [
            "api_key": config.apiKey,
            "format": "json",
            "method": "track.updateNowPlaying",
            "sk": sessionKey,
            "artist": item.artist,
            "track": item.track,
        ]

        if let album = item.album, !album.isEmpty {
            params["album"] = album
        }
        if let duration = item.duration, duration > 0 {
            params["duration"] = String(Int(floor(duration)))
        }

        params["api_sig"] = signLastFMRequest(parameters: params)

        let data = try await postFormURLEncoded(params: params)
        if let (code, message) = try parseAPIErrorIfPresent(data) {
            throw LastFMError.apiError(code: code, message: message)
        }
    }

    /// Up to 50 items per [Last.fm API](https://www.last.fm/api/show/track.scrobble).
    func trackScrobbleBatch(
        items: [LastFMBatchScrobbleItem],
        sessionKey: String
    ) async throws {
        guard !items.isEmpty else { return }
        guard items.count <= 50 else { throw LastFMError.invalidResponse }

        var params: [String: String] = [
            "api_key": config.apiKey,
            "format": "json",
            "method": "track.scrobble",
            "sk": sessionKey,
        ]

        for (i, item) in items.enumerated() {
            params["artist[\(i)]"] = item.artist
            params["track[\(i)]"] = item.track
            let ts = Int(floor(item.startedAt.timeIntervalSince1970))
            params["timestamp[\(i)]"] = String(ts)
            if let album = item.album, !album.isEmpty {
                params["album[\(i)]"] = album
            }
            if let d = item.duration, d > 0 {
                params["duration[\(i)]"] = String(Int(floor(d)))
            }
        }

        params["api_sig"] = signLastFMRequest(parameters: params)

        let data = try await postFormURLEncoded(params: params)
        if let (code, message) = try parseAPIErrorIfPresent(data) {
            throw LastFMError.apiError(code: code, message: message)
        }
    }

    // MARK: - HTTP POST (form)

    private func postFormURLEncoded(params: [String: String]) async throws -> Data {
        let url = URL(string: "https://ws.audioscrobbler.com/2.0/")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formURLEncodedData(from: params)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LastFMError.invalidResponse }
        if let apiError = Self.parseAPIErrorIfPresent(data) {
            throw LastFMError.apiError(code: apiError.code, message: apiError.message)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            throw LastFMError.httpStatus(http.statusCode, body: String(body.prefix(500)))
        }
        return data
    }

    private func parseAPIErrorIfPresent(_ data: Data) throws -> (Int, String)? {
        guard let apiError = Self.parseAPIErrorIfPresent(data) else { return nil }
        return (apiError.code, apiError.message)
    }

    private static let formKeyAllowed = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-._~[]")) // e.g. artist[0]
    private static let formValueAllowed = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-._~ ")) // space → %20 if still present after encoding

    private static func formURLEncodedData(from params: [String: String]) -> Data {
        // Body key order is irrelevant; signature key order is handled in `sign(_:)`.
        var parts: [String] = []
        for (k, v) in params {
            let ek = k.addingPercentEncoding(withAllowedCharacters: formKeyAllowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: formValueAllowed) ?? v
            parts.append("\(ek)=\(ev)")
        }
        return parts.joined(separator: "&").data(using: .utf8) ?? Data()
    }
}
