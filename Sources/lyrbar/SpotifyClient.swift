import Foundation

enum SpotifyError: LocalizedError {
    case http(Int, String)
    var errorDescription: String? {
        switch self { case .http(let c, let m): return "Spotify API error \(c): \(m)" }
    }
}

/// Thin wrapper over the Spotify Web API endpoints lyrbar needs.
final class SpotifyClient {
    private let auth: SpotifyAuth
    init(auth: SpotifyAuth) { self.auth = auth }

    private struct CurrentlyPlaying: Decodable {
        struct Item: Decodable {
            struct Artist: Decodable { var name: String }
            struct Album: Decodable {
                struct Img: Decodable { var url: String; var width: Int? }
                var name: String
                var images: [Img]?
            }
            var id: String?
            var name: String
            var artists: [Artist]
            var album: Album
            var duration_ms: Int
        }
        var is_playing: Bool
        var progress_ms: Int?
        var item: Item?
    }

    /// Fetches the currently playing track, or nil when nothing is playing
    /// (HTTP 204) or only an ad / non-track is active.
    func currentlyPlaying() async throws -> NowPlaying? {
        let token = try await auth.validAccessToken()
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 204 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw SpotifyError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let cp = try JSONDecoder().decode(CurrentlyPlaying.self, from: data)
        guard let item = cp.item, let id = item.id else { return nil }

        // Pick the artwork closest to the size we render (~160px).
        let imgs = item.album.images ?? []
        let art = imgs.min(by: { abs(($0.width ?? 0) - 160) < abs(($1.width ?? 0) - 160) })?.url

        return NowPlaying(
            trackId: id,
            title: item.name,
            artist: item.artists.map(\.name).joined(separator: ", "),
            album: item.album.name,
            durationMs: item.duration_ms,
            progressMs: cp.progress_ms ?? 0,
            isPlaying: cp.is_playing,
            artworkURL: art,
            capturedAt: ProcessInfo.processInfo.systemUptime
        )
    }

    struct QueuedTrack { let id: String; let query: TrackQuery }

    private struct QueueResp: Decodable {
        struct QItem: Decodable {
            struct Artist: Decodable { var name: String }
            struct Album: Decodable { var name: String }
            var id: String?
            var name: String?
            var artists: [Artist]?
            var album: Album?
            var duration_ms: Int?
        }
        var queue: [QItem]?
    }

    /// The next few items in the playback queue, used to pre-load lyrics so the
    /// next track's words are ready the instant it starts.
    func upcoming(limit: Int) async throws -> [QueuedTrack] {
        let token = try await auth.validAccessToken()
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/queue")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return [] }
        let q = try JSONDecoder().decode(QueueResp.self, from: data)
        var out: [QueuedTrack] = []
        for item in (q.queue ?? []) {
            guard let id = item.id, let name = item.name,
                  let artists = item.artists, !artists.isEmpty else { continue }
            out.append(QueuedTrack(id: id, query: TrackQuery(
                title: name,
                artist: artists.map(\.name).joined(separator: ", "),
                album: item.album?.name ?? "",
                durationSec: (item.duration_ms ?? 0) / 1000)))
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: Library sources (for building the offline lyrics library)

    private struct APITrack: Decodable {
        struct Artist: Decodable { var name: String }
        struct Album: Decodable { var name: String }
        var id: String?
        var name: String?
        var artists: [Artist]?
        var album: Album?
        var duration_ms: Int?

        var queued: QueuedTrack? {
            guard let id, let name, let artists, !artists.isEmpty else { return nil }
            return QueuedTrack(id: id, query: TrackQuery(
                title: name,
                artist: artists.map(\.name).joined(separator: ", "),
                album: album?.name ?? "",
                durationSec: (duration_ms ?? 0) / 1000))
        }
    }
    private struct ItemsResp: Decodable { var items: [APITrack]? }
    private struct WrappedResp: Decodable {
        struct Wrap: Decodable { var track: APITrack? }
        var items: [Wrap]?
    }

    private func authedGET(_ url: URL) async throws -> Data {
        let token = try await auth.validAccessToken()
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw SpotifyError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// Top tracks for an affinity window: short_term (~4wk), medium_term (~6mo),
    /// long_term (~1yr). The closest the API gets to "my last year".
    func topTracks(timeRange: String, limit: Int = 50) async throws -> [QueuedTrack] {
        var c = URLComponents(string: "https://api.spotify.com/v1/me/top/tracks")!
        c.queryItems = [.init(name: "time_range", value: timeRange), .init(name: "limit", value: String(limit))]
        let data = try await authedGET(c.url!)
        return (try JSONDecoder().decode(ItemsResp.self, from: data).items ?? []).compactMap(\.queued)
    }

    /// One page of the user's Liked Songs.
    func savedTracks(limit: Int = 50, offset: Int = 0) async throws -> [QueuedTrack] {
        var c = URLComponents(string: "https://api.spotify.com/v1/me/tracks")!
        c.queryItems = [.init(name: "limit", value: String(limit)), .init(name: "offset", value: String(offset))]
        let data = try await authedGET(c.url!)
        return (try JSONDecoder().decode(WrappedResp.self, from: data).items ?? []).compactMap { $0.track?.queued }
    }

    /// The last (up to 50) recently played tracks — the API's hard limit.
    func recentlyPlayed(limit: Int = 50) async throws -> [QueuedTrack] {
        var c = URLComponents(string: "https://api.spotify.com/v1/me/player/recently-played")!
        c.queryItems = [.init(name: "limit", value: String(limit))]
        let data = try await authedGET(c.url!)
        return (try JSONDecoder().decode(WrappedResp.self, from: data).items ?? []).compactMap { $0.track?.queued }
    }

    struct PlaylistRef { let id: String; let name: String; let ownerId: String }

    private struct MeResp: Decodable { var id: String }
    func currentUserId() async throws -> String {
        try JSONDecoder().decode(MeResp.self, from: try await authedGET(URL(string: "https://api.spotify.com/v1/me")!)).id
    }

    /// All playlists in the user's library (owned + followed).
    func playlists() async throws -> [PlaylistRef] {
        struct Resp: Decodable {
            struct PL: Decodable { struct Owner: Decodable { var id: String? }; var id: String?; var name: String?; var owner: Owner? }
            var items: [PL]?
        }
        var out: [PlaylistRef] = []
        var offset = 0
        while offset < 2000 {
            var c = URLComponents(string: "https://api.spotify.com/v1/me/playlists")!
            c.queryItems = [.init(name: "limit", value: "50"), .init(name: "offset", value: String(offset))]
            let page = try JSONDecoder().decode(Resp.self, from: try await authedGET(c.url!)).items ?? []
            if page.isEmpty { break }
            for p in page where p.id != nil {
                out.append(PlaylistRef(id: p.id!, name: p.name ?? "", ownerId: p.owner?.id ?? ""))
            }
            if page.count < 50 { break }
            offset += 50
        }
        return out
    }

    /// All tracks in a playlist (paginated).
    func playlistTracks(_ id: String) async throws -> [QueuedTrack] {
        var out: [QueuedTrack] = []
        var offset = 0
        while offset < 10000 {
            var c = URLComponents(string: "https://api.spotify.com/v1/playlists/\(id)/tracks")!
            c.queryItems = [
                .init(name: "limit", value: "100"),
                .init(name: "offset", value: String(offset)),
                .init(name: "fields", value: "items(track(id,name,artists(name),album(name),duration_ms))"),
            ]
            let page = try JSONDecoder().decode(WrappedResp.self, from: try await authedGET(c.url!)).items ?? []
            if page.isEmpty { break }
            out.append(contentsOf: page.compactMap { $0.track?.queued })
            if page.count < 100 { break }
            offset += 100
        }
        return out
    }

    /// Tracks from the user's saved albums.
    func savedAlbumsTracks() async throws -> [QueuedTrack] {
        struct Resp: Decodable {
            struct Item: Decodable {
                struct Album: Decodable {
                    struct Tracks: Decodable { var items: [APITrack]? }
                    var name: String?
                    var tracks: Tracks?
                }
                var album: Album?
            }
            var items: [Item]?
        }
        var out: [QueuedTrack] = []
        var offset = 0
        while offset < 2000 {
            var c = URLComponents(string: "https://api.spotify.com/v1/me/albums")!
            c.queryItems = [.init(name: "limit", value: "50"), .init(name: "offset", value: String(offset))]
            let page = try JSONDecoder().decode(Resp.self, from: try await authedGET(c.url!)).items ?? []
            if page.isEmpty { break }
            for it in page {
                let albumName = it.album?.name ?? ""
                for t in (it.album?.tracks?.items ?? []) {
                    guard let id = t.id, let name = t.name, let arts = t.artists, !arts.isEmpty else { continue }
                    out.append(QueuedTrack(id: id, query: TrackQuery(
                        title: name, artist: arts.map(\.name).joined(separator: ", "),
                        album: albumName, durationSec: (t.duration_ms ?? 0) / 1000)))
                }
            }
            if page.count < 50 { break }
            offset += 50
        }
        return out
    }

    // MARK: Transport (Premium-only, like all Web API playback control)

    func play() async { await playerCommand("play", method: "PUT") }
    func pause() async { await playerCommand("pause", method: "PUT") }
    func next() async { await playerCommand("next", method: "POST") }
    func previous() async { await playerCommand("previous", method: "POST") }

    private func playerCommand(_ path: String, method: String) async {
        guard let token = try? await auth.validAccessToken() else { return }
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: Devices (Spotify Connect)

    /// A Spotify Connect playback device.
    struct Device: Identifiable {
        let id: String
        let name: String
        let type: String        // "Computer", "Smartphone", "Speaker", …
        let isActive: Bool
        let volumePercent: Int?

        /// An SF Symbol that roughly matches the device type.
        var symbolName: String {
            switch type.lowercased() {
            case "computer":            return "laptopcomputer"
            case "smartphone":          return "iphone"
            case "speaker":             return "hifispeaker.fill"
            case "tv", "avr", "stb":    return "tv"
            case "tablet":              return "ipad"
            case "gameconsole":         return "gamecontroller.fill"
            case "automobile":          return "car.fill"
            case "castaudio", "castvideo": return "wifi"
            default:                    return "music.note"
            }
        }
    }

    private struct DevicesResp: Decodable {
        struct Dev: Decodable {
            var id: String?
            var name: String?
            var type: String?
            var is_active: Bool?
            var volume_percent: Int?
        }
        var devices: [Dev]?
    }

    /// Lists the user's available Spotify Connect devices.
    func devices() async -> [Device] {
        guard let data = try? await authedGET(URL(string: "https://api.spotify.com/v1/me/player/devices")!),
              let resp = try? JSONDecoder().decode(DevicesResp.self, from: data) else { return [] }
        return (resp.devices ?? []).compactMap { d in
            guard let id = d.id, let name = d.name else { return nil }
            return Device(id: id, name: name, type: d.type ?? "",
                          isActive: d.is_active ?? false, volumePercent: d.volume_percent)
        }
    }

    /// Moves playback to another device (Spotify Connect transfer). Keeps the
    /// current play/pause state.
    func transferPlayback(to deviceId: String) async {
        guard let token = try? await auth.validAccessToken() else { return }
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player")!)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["device_ids": [deviceId], "play": true])
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Seeks playback to a position (used by click-to-seek in the popover).
    func seek(toMs ms: Int) async throws {
        let token = try await auth.validAccessToken()
        var comps = URLComponents(string: "https://api.spotify.com/v1/me/player/seek")!
        comps.queryItems = [.init(name: "position_ms", value: String(max(0, ms)))]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
    }
}
