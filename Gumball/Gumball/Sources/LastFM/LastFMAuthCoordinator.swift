import Foundation
import AppKit
import os

/// Console-driven desktop auth coordinator:
/// - auth.getToken
/// - open browser for user approval
/// - poll auth.getSession until success (or timeout)
/// - store session key in Keychain
final class LastFMAuthCoordinator {
    private let log = Logger(subsystem: "com.gumball.Gumball", category: "LastFMAuth")
    private let client: LastFMClient
    private let config: LastFMConfig

    init(config: LastFMConfig) {
        self.config = config
        self.client = LastFMClient(config: config)
    }

    func loadSessionKey() throws -> String? {
        try Keychain.getString(service: config.keychainService, account: config.keychainAccount)
    }

    func clearSession() throws {
        try Keychain.delete(service: config.keychainService, account: config.keychainAccount)
    }

    func ensureSession(interactive: Bool = true) async throws -> String {
        if let existing = try loadSessionKey(), !existing.isEmpty {
            log.info("Last.fm session key already present in Keychain")
            return existing
        }

        guard interactive else {
            throw LastFMError.missingConfig
        }

        let token = try await client.getToken()
        guard let url = client.authURL(token: token) else {
            throw LastFMError.invalidResponse
        }

        log.info("Opening Last.fm auth URL in browser")
        NSWorkspace.shared.open(url)

        let session = try await pollForSession(token: token, timeoutSeconds: 300, intervalSeconds: 5)
        try Keychain.setString(session.key, service: config.keychainService, account: config.keychainAccount)
        log.info("Stored Last.fm session key in Keychain for user=\(session.name, privacy: .public)")
        return session.key
    }

    private func pollForSession(token: String, timeoutSeconds: TimeInterval, intervalSeconds: TimeInterval) async throws -> LastFMSession {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            do {
                let session = try await client.getSession(token: token)
                return session
            } catch {
                if case let LastFMError.apiError(code, _) = error, code != 14, code != 15 {
                    throw error
                }
                // 14/15 (token not yet authorized) or network hiccup: keep polling.
            }
            try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
        }
        throw LastFMError.invalidResponse
    }
}

