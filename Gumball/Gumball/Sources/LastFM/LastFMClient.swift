import Foundation
import CryptoKit

struct LastFMConfig: Sendable {
    var apiKey: String
    var sharedSecret: String
}

enum LastFMError: Error, Sendable {
    case missingConfig
    case httpStatus(Int, body: String)
    case apiError(code: Int, message: String)
    case decodingFailed(String)
    case invalidResponse
    case sessionPollTimeout
}

/// Minimal Last.fm API client for auth + signing.
final class LastFMClient {
    /// Internal so `LastFMTrackScrobble` (same target) can sign POST bodies.
    let config: LastFMConfig
    let session: URLSession

    init(config: LastFMConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func getToken() async throws -> String {
        var params: [String: String] = [
            "method": "auth.getToken",
            "api_key": config.apiKey,
            "format": "json",
        ]
        // auth.getToken requires api_sig; `format` must not be part of the signature (authspec §8).
        params["api_sig"] = signLastFMRequest(parameters: params)
        let url = try makeGETURL(params: params)
        let data = try await fetch(url: url)
        let decoded: TokenResponse
        do {
            decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw LastFMError.decodingFailed(Self.debugBody(data))
        }
        if let err = decoded.error, let msg = decoded.message {
            throw LastFMError.apiError(code: err, message: msg)
        }
        guard let token = decoded.token else { throw LastFMError.invalidResponse }
        return token
    }

    func getSession(token: String) async throws -> LastFMSession {
        var params: [String: String] = [
            "method": "auth.getSession",
            "api_key": config.apiKey,
            "token": token,
            "format": "json",
        ]
        params["api_sig"] = signLastFMRequest(parameters: params)

        let url = try makeGETURL(params: params)
        let data = try await fetch(url: url)
        let decoded: SessionResponse
        do {
            decoded = try JSONDecoder().decode(SessionResponse.self, from: data)
        } catch {
            throw LastFMError.decodingFailed(Self.debugBody(data))
        }
        if let err = decoded.error, let msg = decoded.message {
            throw LastFMError.apiError(code: err, message: msg)
        }
        guard let session = decoded.session else { throw LastFMError.invalidResponse }
        return session
    }

    func getAuthenticatedUsername(sessionKey: String) async throws -> String {
        var params: [String: String] = [
            "method": "user.getInfo",
            "api_key": config.apiKey,
            "sk": sessionKey,
            "format": "json",
        ]
        params["api_sig"] = signLastFMRequest(parameters: params)

        let url = try makeGETURL(params: params)
        let data = try await fetch(url: url)
        let decoded: UserInfoResponse
        do {
            decoded = try JSONDecoder().decode(UserInfoResponse.self, from: data)
        } catch {
            throw LastFMError.decodingFailed(Self.debugBody(data))
        }
        if let err = decoded.error, let msg = decoded.message {
            throw LastFMError.apiError(code: err, message: msg)
        }
        guard let name = decoded.user?.name, !name.isEmpty else {
            throw LastFMError.invalidResponse
        }
        return name
    }

    func artistGetInfo(artist: String) async throws -> LastFMArtistInfo {
        let params: [String: String] = [
            "method": "artist.getInfo",
            "artist": artist,
            "api_key": config.apiKey,
            "format": "json",
        ]
        let url = try makeGETURL(params: params)
        let data = try await fetch(url: url)
        let decoded: ArtistInfoResponse
        do {
            decoded = try JSONDecoder().decode(ArtistInfoResponse.self, from: data)
        } catch {
            throw LastFMError.decodingFailed(Self.debugBody(data))
        }
        if let err = decoded.error, let msg = decoded.message {
            throw LastFMError.apiError(code: err, message: msg)
        }
        guard let body = decoded.artist else { throw LastFMError.invalidResponse }
        return LastFMArtistInfo(name: body.name, playcount: Int(body.playcount) ?? 0)
    }

    /// Returns true if the track is in the user's loved tracks on Last.fm.
    /// Requires `username` for the `userloved` field to be populated in the response.
    func trackGetInfo(artist: String, track: String, username: String) async throws -> Bool {
        let params: [String: String] = [
            "method": "track.getInfo",
            "artist": artist,
            "track": track,
            "username": username,
            "api_key": config.apiKey,
            "format": "json",
        ]
        let url = try makeGETURL(params: params)
        let data = try await fetch(url: url)
        let decoded: TrackInfoResponse
        do {
            decoded = try JSONDecoder().decode(TrackInfoResponse.self, from: data)
        } catch {
            throw LastFMError.decodingFailed(Self.debugBody(data))
        }
        if let err = decoded.error, let msg = decoded.message {
            throw LastFMError.apiError(code: err, message: msg)
        }
        return decoded.track?.userloved == "1"
    }

    func authURL(token: String) -> URL? {
        // Desktop auth flow: user approves in browser.
        var c = URLComponents(string: "https://www.last.fm/api/auth/")
        c?.queryItems = [
            URLQueryItem(name: "api_key", value: config.apiKey),
            URLQueryItem(name: "token", value: token),
        ]
        return c?.url
    }

    // MARK: - Signing

    /// Last.fm authspec §8: `format` and `callback` are sent on the wire but **must not** be included in the `api_sig` hash.
    /// `api_sig` itself is never part of the hash input.
    func signLastFMRequest(parameters: [String: String]) -> String {
        var p = parameters
        p.removeValue(forKey: "api_sig")
        p.removeValue(forKey: "format")
        p.removeValue(forKey: "callback")
        return signSortedParamsForMD5(p)
    }

    /// Sort params alphabetically by name, concat `<name><value>`, append secret, MD5 (hex lowercase).
    private func signSortedParamsForMD5(_ params: [String: String]) -> String {
        let sortedKeys = params.keys.sorted()
        var s = ""
        for k in sortedKeys {
            s.append(k)
            s.append(params[k] ?? "")
        }
        s.append(config.sharedSecret)
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - HTTP

    private func makeGETURL(params: [String: String]) throws -> URL {
        var comps = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw LastFMError.invalidResponse }
        return url
    }

    private func fetch(url: URL) async throws -> Data {
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse else { throw LastFMError.invalidResponse }
        if let apiError = Self.parseAPIErrorIfPresent(data) {
            throw LastFMError.apiError(code: apiError.code, message: apiError.message)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LastFMError.httpStatus(http.statusCode, body: Self.debugBody(data))
        }
        return data
    }

    static func parseAPIErrorIfPresent(_ data: Data) -> (code: Int, message: String)? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let code = obj["error"] as? Int
        else {
            return nil
        }
        return (code, (obj["message"] as? String) ?? "")
    }

    private static func debugBody(_ data: Data, maxLen: Int = 500) -> String {
        let s = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        if s.count <= maxLen { return s }
        return String(s.prefix(maxLen)) + "…"
    }
}

// MARK: - Models

private struct TokenResponse: Decodable {
    var token: String?
    var error: Int?
    var message: String?
}

/// Last.fm returns `subscriber` as either `0` or `"0"` depending on endpoint/version; we only need `name` + `key`.
struct LastFMSession: Decodable, Sendable {
    var name: String
    var key: String

    enum CodingKeys: String, CodingKey {
        case name
        case key
    }
}

private struct SessionResponse: Decodable {
    var session: LastFMSession?
    var error: Int?
    var message: String?
}

private struct UserInfoResponse: Decodable {
    var user: LastFMUserInfo?
    var error: Int?
    var message: String?
}

private struct LastFMUserInfo: Decodable {
    var name: String
}

private struct ArtistInfoResponse: Decodable {
    var artist: ArtistInfoBody?
    var error: Int?
    var message: String?
}

// Last.fm returns numeric fields as strings in artist.getInfo.
private struct ArtistInfoBody: Decodable {
    var name: String
    var playcount: String
}

struct LastFMArtistInfo: Sendable {
    var name: String
    var playcount: Int
}

private struct TrackInfoResponse: Decodable {
    var track: TrackInfoBody?
    var error: Int?
    var message: String?
}

private struct TrackInfoBody: Decodable {
    var userloved: String?  // "0" or "1"
}

