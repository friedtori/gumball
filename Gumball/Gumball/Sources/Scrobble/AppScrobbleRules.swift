import Foundation

struct KnownApp: Identifiable, Sendable {
    let id: String
    let name: String
    let category: Category
    /// App has its own Last.fm scrobbling — enabling Gumball would double-scrobble.
    var nativeLastFM: Bool = false
    /// Blocked out of the box unless the user explicitly enables it.
    var defaultBlocked: Bool = false

    enum Category: String, Sendable {
        case musicPlayer
        case browser
        case videoPlayer

        var label: String {
            switch self {
            case .musicPlayer: return "Music Players"
            case .browser:     return "Browsers"
            case .videoPlayer: return "Video Players"
            }
        }
    }

    var behaviorNote: String {
        if nativeLastFM { return "Has native Last.fm scrobbling — enable only if you've disabled it in the app" }
        switch category {
        case .musicPlayer: return "Trusted"
        case .browser:     return "Music validity check applied"
        case .videoPlayer: return "Disabled by default"
        }
    }
}

@MainActor
final class AppScrobbleRules: ObservableObject {
    static let shared = AppScrobbleRules()

    static let catalog: [KnownApp] = [
        // Music players — trusted by default
        KnownApp(id: "com.apple.Music",           name: "Apple Music",    category: .musicPlayer),
        KnownApp(id: "com.coppertino.Vox",         name: "VOX",            category: .musicPlayer),
        // Music players with native Last.fm — blocked by default
        KnownApp(id: "com.spotify.client",         name: "Spotify",        category: .musicPlayer, nativeLastFM: true,  defaultBlocked: true),
        KnownApp(id: "com.tidal.desktop",          name: "TIDAL",          category: .musicPlayer, nativeLastFM: true,  defaultBlocked: true),
        KnownApp(id: "com.plex.plexamp",           name: "Plexamp",        category: .musicPlayer, nativeLastFM: true,  defaultBlocked: true),
        KnownApp(id: "com.deezer.Deezer",          name: "Deezer",         category: .musicPlayer, nativeLastFM: true,  defaultBlocked: true),
        KnownApp(id: "sh.cider.Cider",             name: "Cider",          category: .musicPlayer, nativeLastFM: true,  defaultBlocked: true),
        // Browsers — music validity check applied
        KnownApp(id: "com.apple.Safari",           name: "Safari",         category: .browser),
        KnownApp(id: "com.google.Chrome",          name: "Google Chrome",  category: .browser),
        KnownApp(id: "org.mozilla.firefox",        name: "Firefox",        category: .browser),
        KnownApp(id: "company.thebrowser.Browser", name: "Arc",            category: .browser),
        KnownApp(id: "com.microsoft.edgemac",      name: "Microsoft Edge", category: .browser),
        KnownApp(id: "com.brave.Browser",          name: "Brave",          category: .browser),
        KnownApp(id: "com.operasoftware.Opera",    name: "Opera",          category: .browser),
        KnownApp(id: "com.vivaldi.Vivaldi",        name: "Vivaldi",        category: .browser),
        KnownApp(id: "com.kagi.kagimacOS",         name: "Orion",          category: .browser),
        KnownApp(id: "com.google.Chrome.canary",   name: "Chrome Canary",  category: .browser),
        // Video players — blocked by default
        KnownApp(id: "org.videolan.vlc",           name: "VLC",            category: .videoPlayer, defaultBlocked: true),
        KnownApp(id: "com.colliderli.iina",        name: "IINA",           category: .videoPlayer, defaultBlocked: true),
        KnownApp(id: "com.apple.QuickTimePlayerX", name: "QuickTime",      category: .videoPlayer, defaultBlocked: true),
        KnownApp(id: "com.firecore.infuse",        name: "Infuse",         category: .videoPlayer, defaultBlocked: true),
    ]

    /// Explicit user overrides: bundleID → enabled (true) or blocked (false).
    /// Apps not present here fall back to their `defaultBlocked` value.
    @Published private(set) var overrides: [String: Bool] = [:]

    private let key = "scrobble.sourceOverrides"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let stored = try? JSONDecoder().decode([String: Bool].self, from: data) {
            overrides = stored
        }
    }

    func isBlocked(_ bundleID: String) -> Bool {
        if let explicit = overrides[bundleID] { return !explicit }
        return AppScrobbleRules.catalog.first { $0.id == bundleID }?.defaultBlocked ?? false
    }

    func setEnabled(_ enabled: Bool, for bundleID: String) {
        overrides[bundleID] = enabled
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
