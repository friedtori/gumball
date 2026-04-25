import Foundation
import CryptoKit

struct LastFMConfig: Sendable {
    var apiKey: String
    var sharedSecret: String

    /// Keychain service/account used for session key storage.
    var keychainService: String = "com.gumball.Gumball.lastfm"
    var keychainAccount: String = "sessionKey"
}

enum LastFMError: Error, Sendable {
    case missingConfig
    case httpStatus(Int)
    case apiError(code: Int, message: String)
    case decodingFailed
    case invalidResponse
}

/// Minimal Last.fm API client for auth + signing.
final class LastFMClient {
    private let config: LastFMConfig
    private let session: URLSession

    init(config: LastFMConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func getToken() async throws -> String {
        let params: [String: String] = [
            "method": "auth.getToken",
            "api_key": config.apiKey,
            "format": "json",
        ]
        let url = try makeGETURL(params: params)
        let data = try await fetch(url: url)
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
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
        params["api_sig"] = sign(params: params)

        let url = try makeGETURL(params: params)
        let data = try await fetch(url: url)
        let decoded = try JSONDecoder().decode(SessionResponse.self, from: data)
        if let err = decoded.error, let msg = decoded.message {
            throw LastFMError.apiError(code: err, message: msg)
        }
        guard let session = decoded.session else { throw LastFMError.invalidResponse }
        return session
    }

    func authURL(token: String) -> URL? {
        // Desktop auth flow: user approves in browser.
        URL(string: "https://www.last.fm/api/auth/?api_key=\(config.apiKey)&token=\(token)")
    }

    // MARK: - Signing

    /// Per spec: sort params alphabetically by name, concat `<name><value>`, append secret, MD5.
    func sign(params: [String: String]) -> String {
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
        guard (200..<300).contains(http.statusCode) else { throw LastFMError.httpStatus(http.statusCode) }
        return data
    }
}

// MARK: - Models

private struct TokenResponse: Decodable {
    var token: String?
    var error: Int?
    var message: String?
}

struct LastFMSession: Decodable, Sendable {
    var name: String
    var key: String
    var subscriber: Int?
}

private struct SessionResponse: Decodable {
    var session: LastFMSession?
    var error: Int?
    var message: String?
}

