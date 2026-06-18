import Foundation

struct LibraryProgress { var done: Int; var total: Int; var phase: String }

/// Builds the offline lyrics library by pulling the user's top tracks, Liked
/// Songs, recently-played, owned playlists, and saved albums, then fetching +
/// caching lyrics for each.
///
/// Note: Spotify's Web API does not expose a full year of play history — the
/// closest proxies are top-tracks (long/medium/short term) plus the user's
/// saved content. A complete year requires the GDPR "Extended streaming
/// history" export, which isn't available through the API.
final class LibraryBuilder {
    static let shared = LibraryBuilder()
    private(set) var isRunning = false

    struct Result { var added: Int; var scanned: Int; var totalTracks: Int; var sources: String; var note: String? }

    private let trackCap = 20000

    func run(client: SpotifyClient, store: LyricsStore, kind: LyricsProviderKind,
             progress: @escaping (LibraryProgress) -> Void) async -> Result {
        if isRunning { return Result(added: 0, scanned: 0, totalTracks: 0, sources: "", note: "Already running") }
        isRunning = true
        defer { isRunning = false }

        var tracks: [String: TrackQuery] = [:]
        var counts: [(String, Int)] = []
        var note: String?
        func add(_ label: String, _ list: [SpotifyClient.QueuedTrack]) {
            for t in list where tracks.count < trackCap { tracks[t.id] = t.query }
            counts.append((label, list.count))
        }

        progress(LibraryProgress(done: 0, total: 0, phase: "Gathering top tracks…"))
        for range in ["long_term", "medium_term", "short_term"] {
            do { add("top", try await client.topTracks(timeRange: range)) }
            catch { note = humanError(error) }
        }

        progress(LibraryProgress(done: 0, total: 0, phase: "Gathering Liked Songs…"))
        var liked: [SpotifyClient.QueuedTrack] = [], offset = 0
        while offset < 10000 {
            do {
                let page = try await client.savedTracks(limit: 50, offset: offset)
                if page.isEmpty { break }
                liked.append(contentsOf: page)
                if page.count < 50 { break }
                offset += 50
            } catch { note = humanError(error); break }
        }
        add("liked", liked)

        do { add("recent", try await client.recentlyPlayed()) }
        catch { note = humanError(error) }

        // Playlists you own — where most people's libraries actually live.
        progress(LibraryProgress(done: 0, total: 0, phase: "Scanning playlists…"))
        let me = try? await client.currentUserId()
        if let all = try? await client.playlists() {
            let owned = all.filter { me == nil || $0.ownerId == me }
            var plTracks: [SpotifyClient.QueuedTrack] = []
            for pl in owned where tracks.count < trackCap {
                if let t = try? await client.playlistTracks(pl.id) { plTracks.append(contentsOf: t) }
            }
            add("playlists", plTracks)
        }

        progress(LibraryProgress(done: 0, total: 0, phase: "Scanning saved albums…"))
        if let albumTracks = try? await client.savedAlbumsTracks() { add("albums", albumTracks) }

        // Build a readable per-source breakdown (raw counts, pre-dedup).
        let merged = Dictionary(counts.map { ($0.0, $0.1) }, uniquingKeysWith: +)
        let order = ["top", "liked", "recent", "playlists", "albums"]
        let sources = order.compactMap { k in merged[k].map { "\(k) \($0)" } }.joined(separator: " · ")

        if tracks.isEmpty {
            return Result(added: 0, scanned: 0, totalTracks: 0, sources: sources,
                          note: note ?? "No tracks found. You may need to log out and back in to grant library access.")
        }

        let items = tracks.filter { !store.hasLyrics($0.key) }.map { ($0.key, $0.value) }
        let total = items.count
        var done = 0, added = 0
        progress(LibraryProgress(done: 0, total: total, phase: "Fetching lyrics…"))

        // Batched concurrency — gentle on LRCLIB while still parallel.
        let batchSize = 6
        var start = 0
        while start < items.count {
            let batch = Array(items[start..<min(start + batchSize, items.count)])
            await withTaskGroup(of: Bool.self) { group in
                for (id, q) in batch {
                    group.addTask {
                        let res = await LyricsService.resolve(q, kind: kind)
                        guard !res.isEmpty else { return false }
                        store.upsert(trackId: id, query: q, candidates: res, selected: 0)
                        return true
                    }
                }
                for await ok in group {
                    done += 1
                    if ok { added += 1 }
                    progress(LibraryProgress(done: done, total: total, phase: "Fetching lyrics…"))
                }
            }
            start += batchSize
        }
        return Result(added: added, scanned: total, totalTracks: store.trackCount(), sources: sources, note: note)
    }

    private func humanError(_ error: Error) -> String {
        if case SpotifyError.http(403, _) = error {
            return "Library access denied — log out and back in to grant the new permissions."
        }
        return error.localizedDescription
    }
}
