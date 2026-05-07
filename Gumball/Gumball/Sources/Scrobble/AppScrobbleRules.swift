import Foundation

struct KnownApp: Identifiable, Sendable {
    let id: String
    let name: String
    let category: Category

    enum Category: Sendable {
        case music
        case streaming
        case browser

        var defaultBehaviorLabel: String {
            switch self {
            case .music:               return "Trusted"
            case .streaming, .browser: return "Music validity check applied"
            }
        }
    }
}

@MainActor
final class AppScrobbleRules: ObservableObject {
    static let shared = AppScrobbleRules()

    static let catalog: [KnownApp] = [
        // Music apps — trusted by default
        KnownApp(id: "com.apple.Music",         name: "Apple Music",    category: .music),
        KnownApp(id: "com.tidal.desktop",        name: "TIDAL",          category: .music),
        KnownApp(id: "com.plex.plexamp",         name: "Plexamp",        category: .music),
        KnownApp(id: "com.coppertino.Vox",       name: "VOX",            category: .music),
        KnownApp(id: "sh.cider.Cider",           name: "Cider",          category: .music),
        KnownApp(id: "com.deezer.Deezer",        name: "Deezer",         category: .music),
        // Streaming — music validity check applied
        KnownApp(id: "com.spotify.client",       name: "Spotify",        category: .streaming),
        // Browsers — music validity check applied
        KnownApp(id: "com.apple.Safari",         name: "Safari",         category: .browser),
        KnownApp(id: "com.google.Chrome",        name: "Google Chrome",  category: .browser),
        KnownApp(id: "org.mozilla.firefox",      name: "Firefox",        category: .browser),
        KnownApp(id: "company.thebrowser.Browser", name: "Arc",          category: .browser),
        KnownApp(id: "com.microsoft.edgemac",    name: "Microsoft Edge", category: .browser),
        KnownApp(id: "com.brave.Browser",        name: "Brave",          category: .browser),
        KnownApp(id: "com.operasoftware.Opera",  name: "Opera",          category: .browser),
        KnownApp(id: "com.vivaldi.Vivaldi",      name: "Vivaldi",        category: .browser),
        KnownApp(id: "com.kagi.kagimacOS",       name: "Orion",          category: .browser),
        KnownApp(id: "com.google.Chrome.canary", name: "Chrome Canary",  category: .browser),
    ]

    @Published private(set) var blockedBundleIDs: Set<String> = []

    private let key = "scrobble.blockedSources"

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: key) ?? []
        blockedBundleIDs = Set(stored)
    }

    func isBlocked(_ bundleID: String) -> Bool {
        blockedBundleIDs.contains(bundleID)
    }

    func setEnabled(_ enabled: Bool, for bundleID: String) {
        if enabled {
            blockedBundleIDs.remove(bundleID)
        } else {
            blockedBundleIDs.insert(bundleID)
        }
        UserDefaults.standard.set(Array(blockedBundleIDs), forKey: key)
    }
}
