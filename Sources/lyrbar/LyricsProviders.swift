import Foundation

protocol LyricsProvider {
    var name: String { get }
    /// Returns an ordered list of candidate lyric sets (best first).
    func fetchCandidates(_ q: TrackQuery) async -> [LyricsResult]
}

enum LyricsService {
    /// Fast path: the user's chosen provider only (LRCLIB for Auto). Shown as
    /// soon as it returns so lyrics don't wait on slower secondary sources.
    static func primary(for q: TrackQuery, kind: LyricsProviderKind) async -> [LyricsResult] {
        switch kind {
        case .netease: return await NetEaseProvider().fetchCandidates(q)
        case .lrclib, .auto: return await LRCLIBProvider().fetchCandidates(q)
        }
    }

    /// Secondary / fallback source, fetched lazily (used when the primary is
    /// empty, or in the background so "Next match" has alternatives to offer).
    static func secondary(for q: TrackQuery, kind: LyricsProviderKind) async -> [LyricsResult] {
        guard kind == .auto else { return [] }
        return await NetEaseProvider().fetchCandidates(q)
    }

    /// Full resolution: primary + fallback + alternatives, with wrong-script
    /// candidates filtered out in Auto mode. Shared by live fetch, prefetch,
    /// and the library importer.
    static func resolve(_ q: TrackQuery, kind: LyricsProviderKind) async -> [LyricsResult] {
        func keep(_ r: [LyricsResult]) -> [LyricsResult] {
            guard kind == .auto else { return r }   // respect an explicit choice
            return r.filter { !isScriptMismatch($0, query: q) }
        }
        var results = keep(await primary(for: q, kind: kind))
        if results.isEmpty {
            results = keep(await secondary(for: q, kind: kind))
        } else if kind == .auto {
            results.append(contentsOf: keep(await secondary(for: q, kind: kind)))
        }
        return results
    }
}

private func http(_ url: URL, headers: [String: String] = [:]) async -> Data? {
    var req = URLRequest(url: url)
    req.timeoutInterval = 10
    req.setValue("lyrbar/0.1 (+https://github.com/lyrbar/lyrbar)", forHTTPHeaderField: "User-Agent")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) { return nil }
        return data
    } catch {
        return nil
    }
}

private func levenshteinRatio(_ a: String, _ b: String) -> Double {
    let s = a.lowercased(), t = b.lowercased()
    if s == t { return 1 }
    if s.isEmpty || t.isEmpty { return 0 }
    let sc = Array(s), tc = Array(t)
    var prev = Array(0...tc.count)
    var cur = [Int](repeating: 0, count: tc.count + 1)
    for i in 1...sc.count {
        cur[0] = i
        for j in 1...tc.count {
            let cost = sc[i-1] == tc[j-1] ? 0 : 1
            cur[j] = min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost)
        }
        swap(&prev, &cur)
    }
    let dist = Double(prev[tc.count])
    return 1 - dist / Double(max(sc.count, tc.count))
}

/// Artist-name similarity that tolerates features, "&", and ordering.
func artistMatch(_ a: String, _ b: String) -> Double {
    let x = a.lowercased(), y = b.lowercased()
    if x == y { return 1 }
    if x.contains(y) || y.contains(x) { return 0.9 }
    let sep = CharacterSet(charactersIn: ",&")
    let xa = x.components(separatedBy: sep).first?.trimmingCharacters(in: .whitespaces) ?? x
    let ya = y.components(separatedBy: sep).first?.trimmingCharacters(in: .whitespaces) ?? y
    return max(levenshteinRatio(x, y), levenshteinRatio(xa, ya))
}

private func isCJK(_ u: Unicode.Scalar) -> Bool {
    let v = u.value
    return (0x3040...0x30FF).contains(v)   // Hiragana / Katakana
        || (0x3400...0x9FFF).contains(v)   // CJK ideographs
        || (0xF900...0xFAFF).contains(v)   // CJK compatibility
        || (0xAC00...0xD7AF).contains(v)   // Hangul
}

func containsCJK(_ s: String) -> Bool { s.unicodeScalars.contains(where: isCJK) }

private func fractionCJK(_ s: String) -> Double {
    let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
    guard !letters.isEmpty else { return 0 }
    return Double(letters.filter(isCJK).count) / Double(letters.count)
}

/// True when a candidate's lyrics are mostly CJK but the track (title+artist)
/// has no CJK at all — the classic "Chinese lyrics for an English song" case.
func isScriptMismatch(_ r: LyricsResult, query: TrackQuery) -> Bool {
    let q = query.title + " " + query.artist
    if containsCJK(q) { return false }
    let text = r.lines.isEmpty ? (r.plain ?? "") : r.lines.map(\.text).joined(separator: " ")
    return fractionCJK(text) > 0.25
}

// MARK: - LRCLIB

struct LRCLIBProvider: LyricsProvider {
    let name = "LRCLIB"

    private struct Row: Decodable {
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    func fetchCandidates(_ q: TrackQuery) async -> [LyricsResult] {
        var results: [LyricsResult] = []

        // 1) Exact-ish match by signature (best when it hits).
        var getC = URLComponents(string: "https://lrclib.net/api/get")!
        getC.queryItems = [
            .init(name: "artist_name", value: q.artist),
            .init(name: "track_name", value: q.title),
            .init(name: "album_name", value: q.album),
            .init(name: "duration", value: String(q.durationSec)),
        ]
        if let url = getC.url, let data = await http(url),
           let row = try? JSONDecoder().decode(Row.self, from: data) {
            if let r = makeResult(row, exact: true) { results.append(r) }
        }

        // 2) Fuzzy search → multiple candidates the user can flip between.
        var searchC = URLComponents(string: "https://lrclib.net/api/search")!
        searchC.queryItems = [
            .init(name: "track_name", value: q.title),
            .init(name: "artist_name", value: q.artist),
        ]
        if let url = searchC.url, let data = await http(url),
           let rows = try? JSONDecoder().decode([Row].self, from: data) {
            let scored = rows.compactMap { row -> (Double, LyricsResult)? in
                guard let r = makeResult(row, exact: false) else { return nil }
                let titleScore = levenshteinRatio(row.trackName ?? "", q.title)
                let artistScore = artistMatch(row.artistName ?? "", q.artist)
                // Heavy duration penalty: a wildly different runtime is a strong
                // signal it's a different recording / wrong match.
                let durDelta = abs((row.duration ?? 0) - Double(q.durationSec))
                let durPenalty = min(durDelta / 8.0, 2.0)
                let score = 0.5 * titleScore + 0.5 * artistScore
                            - durPenalty + (r.synced ? 0.25 : 0)
                // Reject clear non-matches (wrong song that merely shares a title).
                guard titleScore >= 0.45, artistScore >= 0.3 else { return nil }
                return (score, r)
            }
            .sorted { $0.0 > $1.0 }
            .map { $0.1 }
            results.append(contentsOf: scored)
        }

        return dedup(results)
    }

    private func makeResult(_ row: Row, exact: Bool) -> LyricsResult? {
        if row.instrumental == true {
            return LyricsResult(lines: [], plain: "♪ (instrumental)", source: name,
                                label: "LRCLIB · instrumental")
        }
        let lines = row.syncedLyrics.map(LRC.parse) ?? []
        guard !lines.isEmpty || (row.plainLyrics?.isEmpty == false) else { return nil }
        let dur = row.duration.map { Int($0) } ?? 0
        let tag = exact ? "exact" : "\(dur/60):\(String(format: "%02d", dur%60))"
        let label = "LRCLIB · \(row.albumName ?? "?") · \(tag)\(lines.isEmpty ? " (plain)" : "")"
        return LyricsResult(lines: lines, plain: row.plainLyrics, source: name, label: label)
    }
}

// MARK: - NetEase (secondary source)

struct NetEaseProvider: LyricsProvider {
    let name = "NetEase"

    private struct SearchResp: Decodable {
        struct Result: Decodable {
            struct Song: Decodable {
                struct Artist: Decodable { var name: String? }
                struct Album: Decodable { var name: String? }
                var id: Int
                var name: String?
                var artists: [Artist]?
                var album: Album?
                var duration: Int?
            }
            var songs: [Song]?
        }
        var result: Result?
    }

    private struct LyricResp: Decodable {
        struct LRCBlock: Decodable { var lyric: String? }
        var lrc: LRCBlock?
        var klyric: LRCBlock?
    }

    func fetchCandidates(_ q: TrackQuery) async -> [LyricsResult] {
        var sc = URLComponents(string: "https://music.163.com/api/search/get")!
        sc.queryItems = [
            .init(name: "s", value: "\(q.title) \(q.artist)"),
            .init(name: "type", value: "1"),
            .init(name: "limit", value: "5"),
        ]
        guard let url = sc.url,
              let data = await http(url, headers: ["Referer": "https://music.163.com"]),
              let resp = try? JSONDecoder().decode(SearchResp.self, from: data),
              let songs = resp.result?.songs, !songs.isEmpty else {
            return []
        }

        let candidates = Array(songs.prefix(4))
        return await withTaskGroup(of: LyricsResult?.self) { group in
            for song in candidates {
                group.addTask { await Self.fetchLyric(for: song) }
            }
            var out: [LyricsResult] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
    }

    private static func fetchLyric(for song: SearchResp.Result.Song) async -> LyricsResult? {
        var lc = URLComponents(string: "https://music.163.com/api/song/lyric")!
        lc.queryItems = [
            .init(name: "id", value: String(song.id)),
            .init(name: "lv", value: "1"),
            .init(name: "tv", value: "1"),
        ]
        guard let lurl = lc.url,
              let ldata = await http(lurl, headers: ["Referer": "https://music.163.com"]),
              let lyr = try? JSONDecoder().decode(LyricResp.self, from: ldata),
              let lrcText = lyr.lrc?.lyric, !lrcText.isEmpty else { return nil }
        let lines = LRC.parse(lrcText)
        let artist = song.artists?.compactMap(\.name).joined(separator: ", ") ?? "?"
        let label = "NetEase · \(song.name ?? "?") — \(artist)\(lines.isEmpty ? " (plain)" : "")"
        return LyricsResult(lines: lines, plain: lines.isEmpty ? lrcText : nil,
                            source: "NetEase", label: label)
    }
}

private func dedup(_ results: [LyricsResult]) -> [LyricsResult] {
    var seen = Set<String>()
    var out: [LyricsResult] = []
    for r in results {
        let key = "\(r.source)|\(r.lines.count)|\(r.lines.first?.text ?? r.plain?.prefix(40).description ?? "")"
        if seen.insert(key).inserted { out.append(r) }
    }
    return out
}
