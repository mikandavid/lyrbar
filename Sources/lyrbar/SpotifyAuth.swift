import Foundation
import CryptoKit
import AppKit

enum AuthError: LocalizedError {
    case noClientId
    case tokenExchangeFailed(String)
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .noClientId: return "No Spotify client ID configured. Run `lyrbar setup <client_id>` or use the menu."
        case .tokenExchangeFailed(let m): return "Spotify token exchange failed: \(m)"
        case .notLoggedIn: return "Not logged in to Spotify."
        }
    }
}

/// Handles the OAuth Authorization Code + PKCE flow and access-token refresh.
final class SpotifyAuth {
    private let settings = Settings.shared
    private let store = TokenStore.shared
    private var pendingServer: LoopbackServer?

    var isLoggedIn: Bool { store.load() != nil }

    // MARK: Login

    /// Runs the interactive login: opens the browser and waits for the callback.
    func login() async throws {
        guard let clientId = settings.clientId, !clientId.isEmpty else { throw AuthError.noClientId }

        let verifier = Self.randomVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomVerifier().prefix(16).description

        var authC = URLComponents(string: "https://accounts.spotify.com/authorize")!
        authC.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: settings.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: Settings.scopes),
            .init(name: "state", value: state),
        ]

        let server = LoopbackServer()
        pendingServer = server

        // Start listening before opening the browser to avoid a race.
        async let code = server.waitForCode(port: settings.port)
        if let url = authC.url { NSWorkspace.shared.open(url) }

        let authCode = try await code
        pendingServer = nil
        try await exchange(code: authCode, verifier: verifier, clientId: clientId)
    }

    func cancelLogin() {
        pendingServer?.cancel()
        pendingServer = nil
    }

    private func exchange(code: String, verifier: String, clientId: String) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": settings.redirectURI,
            "client_id": clientId,
            "code_verifier": verifier,
        ])
        try await performTokenRequest(req)
    }

    // MARK: Token access / refresh

    /// Returns a valid access token, refreshing if it is expired or near expiry.
    func validAccessToken() async throws -> String {
        guard var tokens = store.load() else { throw AuthError.notLoggedIn }
        if Date().timeIntervalSince1970 < tokens.expiresAt - 30 {
            return tokens.accessToken
        }
        guard let clientId = settings.clientId else { throw AuthError.noClientId }
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form([
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": clientId,
        ])
        try await performTokenRequest(req, fallbackRefresh: tokens.refreshToken)
        tokens = store.load()!
        return tokens.accessToken
    }

    private struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double
    }

    private func performTokenRequest(_ req: URLRequest, fallbackRefresh: String? = nil) async throws {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw AuthError.tokenExchangeFailed(body)
        }
        let tr = try JSONDecoder().decode(TokenResponse.self, from: data)
        let tokens = StoredTokens(
            accessToken: tr.access_token,
            refreshToken: tr.refresh_token ?? fallbackRefresh ?? "",
            expiresAt: Date().timeIntervalSince1970 + tr.expires_in
        )
        store.save(tokens)
    }

    // MARK: PKCE helpers

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return base64url(Data(hash))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func form(_ params: [String: String]) -> Data {
        params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)!
    }
}

extension CharacterSet {
    /// URL query value allowed set (stricter than .urlQueryAllowed which keeps &=+).
    static let urlQueryValueAllowed: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()
}
