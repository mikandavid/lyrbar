import Foundation

/// Persistent, runtime-tweakable settings backed by a stable preferences
/// domain (so it works for a SwiftPM executable with no app bundle).
final class Settings {
    static let shared = Settings()

    private let defaults: UserDefaults

    private init() {
        // A fixed suite name → ~/Library/Preferences/com.lyrbar.app.plist
        self.defaults = UserDefaults(suiteName: "com.lyrbar.app") ?? .standard
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.width: 260.0,
            Keys.scrollLongLines: true,
            Keys.globalOffsetMs: 0,
            Keys.provider: LyricsProviderKind.auto.rawValue,
            Keys.port: 8888,
            Keys.pollMs: 5000,
        ])
    }

    enum Keys {
        static let clientId = "clientId"
        static let width = "width"
        static let scrollLongLines = "scrollLongLines"
        static let globalOffsetMs = "globalOffsetMs"
        static let provider = "provider"
        static let port = "port"
        static let pollMs = "pollMs"
    }

    var clientId: String? {
        get { defaults.string(forKey: Keys.clientId) }
        set { defaults.set(newValue, forKey: Keys.clientId) }
    }

    /// Status item display width in points (the "menu bar width" slider).
    var width: Double {
        get { defaults.double(forKey: Keys.width) }
        set { defaults.set(min(max(newValue, 120), 700), forKey: Keys.width) }
    }
    static let widthRange: ClosedRange<Double> = 120...700

    /// When enabled, synced lyric lines that exceed the menu bar width pan
    /// across during their active display window. When disabled, they truncate.
    var scrollLongLines: Bool {
        get { defaults.bool(forKey: Keys.scrollLongLines) }
        set { defaults.set(newValue, forKey: Keys.scrollLongLines) }
    }

    /// Range for the per-song lyric offset slider (ms). The value itself lives
    /// in the lyrics store, keyed per track — see `LyricsEngine.currentOffsetMs`.
    static let offsetRange: ClosedRange<Double> = -5000...5000

    /// User-wide lyric timing offset in ms. This composes with each song's
    /// saved offset, so users can set a personal baseline and still tune tracks.
    var globalOffsetMs: Int {
        get { min(max(defaults.integer(forKey: Keys.globalOffsetMs), -5000), 5000) }
        set { defaults.set(min(max(newValue, -5000), 5000), forKey: Keys.globalOffsetMs) }
    }

    var provider: LyricsProviderKind {
        get { LyricsProviderKind(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Keys.provider) }
    }

    var port: UInt16 {
        get { UInt16(defaults.integer(forKey: Keys.port)) }
        set { defaults.set(Int(newValue), forKey: Keys.port) }
    }

    var pollMs: Int {
        get { max(2000, defaults.integer(forKey: Keys.pollMs)) }
        set { defaults.set(newValue, forKey: Keys.pollMs) }
    }

    var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    static let scopes = "user-read-currently-playing user-read-playback-state user-modify-playback-state user-top-read user-library-read user-read-recently-played playlist-read-private playlist-read-collaborative"
}

enum LyricsProviderKind: String, CaseIterable {
    case auto
    case lrclib
    case netease

    var display: String {
        switch self {
        case .auto: return "Auto (LRCLIB → NetEase)"
        case .lrclib: return "LRCLIB"
        case .netease: return "NetEase"
        }
    }
}
