import AppKit
import Combine
import Foundation
import SwiftUI

enum LastFMAuthStatus: String {
    case notConfigured = "Not configured"
    case authorizing = "Authorizing"
    case authorized = "Authorized"
    case failed = "Auth failed"
}

@MainActor
final class AppStatusBridge: ObservableObject {
    static let shared = AppStatusBridge()

    @Published var authStatus: LastFMAuthStatus = .notConfigured
    @Published var currentTrack: String = "Nothing playing"
    @Published var pendingCount: Int = 0

    @Published var isPlaying: Bool = false
    @Published var trackTitle: String? = nil
    @Published var trackArtist: String? = nil
    @Published var trackAlbum: String? = nil
    @Published var artworkImage: NSImage? = nil

    private init() {}
}

/// Bridges the shared `ScrobbleQueue` actor into SwiftUI for the temporary debug window.
@MainActor
final class QueueDebugBridge: ObservableObject {
    static let shared = QueueDebugBridge()

    private(set) var queue: ScrobbleQueue?
    @Published private(set) var rows: [ScrobbleQueue.Row] = []

    private init() {}

    func attachQueue(_ queue: ScrobbleQueue?) {
        self.queue = queue
    }

    func detachQueue() {
        queue = nil
        rows = []
    }

    func refresh() async {
        guard let queue else {
            rows = []
            AppStatusBridge.shared.pendingCount = 0
            return
        }
        do {
            rows = try await queue.fetchRecentForDebug(limit: 200)
            AppStatusBridge.shared.pendingCount = (try? await queue.countPending()) ?? 0
        } catch {
            rows = []
            AppStatusBridge.shared.pendingCount = 0
        }
    }
}
