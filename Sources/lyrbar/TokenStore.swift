import Foundation

struct StoredTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: TimeInterval   // seconds since 1970
}

/// Persists Spotify tokens to ~/.config/lyrbar/tokens.json with 0600 perms.
final class TokenStore {
    static let shared = TokenStore()

    private let url: URL

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lyrbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("tokens.json")
    }

    func load() -> StoredTokens? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StoredTokens.self, from: data)
    }

    func save(_ tokens: StoredTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
