import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Persistent, long-term lyrics cache backed by SQLite. Thread-safe: all
/// database access is serialised on a private queue, so it can be called from
/// the main actor and from background prefetch/import tasks alike.
final class LyricsStore {
    static let shared = LyricsStore()

    struct Entry { var candidates: [LyricsResult]; var selected: Int; var offsetMs: Int }

    private var db: OpaquePointer?
    private let q = DispatchQueue(label: "com.lyrbar.store")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lyrbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("lyrics.sqlite3").path
        q.sync {
            sqlite3_open(path, &db)
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(db, """
                CREATE TABLE IF NOT EXISTS lyrics(
                    track_id TEXT PRIMARY KEY,
                    title TEXT, artist TEXT, album TEXT, duration INTEGER,
                    candidates TEXT NOT NULL,
                    selected INTEGER NOT NULL DEFAULT 0,
                    offset_ms INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS rejected(
                    track_id TEXT NOT NULL,
                    fingerprint TEXT NOT NULL,
                    PRIMARY KEY(track_id, fingerprint)
                );
                """, nil, nil, nil)
            // Migrate older databases that predate the per-song offset column.
            sqlite3_exec(db, "ALTER TABLE lyrics ADD COLUMN offset_ms INTEGER NOT NULL DEFAULT 0;", nil, nil, nil)
        }
    }

    // MARK: Reads

    /// Returns cached candidates with trashed (rejected) ones filtered out and
    /// the saved selection clamped. nil when there's nothing usable cached.
    func entry(for trackId: String) -> Entry? {
        q.sync {
            guard let row = rawRow(trackId) else { return nil }
            let rejected = rejectedSet(trackId)
            let filtered = row.candidates.filter { !rejected.contains($0.fingerprint) }
            guard !filtered.isEmpty else { return nil }
            return Entry(candidates: filtered,
                         selected: min(max(0, row.selected), filtered.count - 1),
                         offsetMs: row.offsetMs)
        }
    }

    /// The saved per-song lyric offset (0 if none stored yet).
    func offset(_ trackId: String) -> Int {
        q.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT offset_ms FROM lyrics WHERE track_id=?;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            bindText(stmt, 1, trackId)
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    /// True only when there are usable (non-rejected, non-empty) lyrics cached.
    func hasLyrics(_ trackId: String) -> Bool { entry(for: trackId) != nil }

    /// Fingerprints the user has trashed for this track.
    func rejected(_ trackId: String) -> Set<String> { q.sync { rejectedSet(trackId) } }

    func trackCount() -> Int {
        q.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM lyrics WHERE candidates != '[]';", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    // MARK: Writes

    func upsert(trackId: String, query: TrackQuery, candidates: [LyricsResult], selected: Int) {
        guard let json = try? encoder.encode(candidates),
              let jsonStr = String(data: json, encoding: .utf8) else { return }
        q.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                INSERT INTO lyrics(track_id,title,artist,album,duration,candidates,selected,updated_at)
                VALUES(?,?,?,?,?,?,?,?)
                ON CONFLICT(track_id) DO UPDATE SET
                    title=excluded.title, artist=excluded.artist, album=excluded.album,
                    duration=excluded.duration, candidates=excluded.candidates,
                    selected=excluded.selected, updated_at=excluded.updated_at;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            bindText(stmt, 1, trackId)
            bindText(stmt, 2, query.title)
            bindText(stmt, 3, query.artist)
            bindText(stmt, 4, query.album)
            sqlite3_bind_int(stmt, 5, Int32(query.durationSec))
            bindText(stmt, 6, jsonStr)
            sqlite3_bind_int(stmt, 7, Int32(selected))
            sqlite3_bind_double(stmt, 8, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    func setSelected(_ trackId: String, index: Int) {
        q.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "UPDATE lyrics SET selected=? WHERE track_id=?;", -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int(stmt, 1, Int32(index))
            bindText(stmt, 2, trackId)
            sqlite3_step(stmt)
        }
    }

    /// Persists the per-song lyric offset. No-op if the track isn't stored yet
    /// (there are no lyrics to offset in that case).
    func setOffset(_ trackId: String, ms: Int) {
        q.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "UPDATE lyrics SET offset_ms=? WHERE track_id=?;", -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int(stmt, 1, Int32(ms))
            bindText(stmt, 2, trackId)
            sqlite3_step(stmt)
        }
    }

    /// Records a candidate as a wrong match so it's never shown for this track again.
    func reject(_ trackId: String, fingerprint: String) {
        q.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO rejected(track_id,fingerprint) VALUES(?,?);", -1, &stmt, nil) == SQLITE_OK else { return }
            bindText(stmt, 1, trackId)
            bindText(stmt, 2, fingerprint)
            sqlite3_step(stmt)
        }
    }

    // MARK: Private helpers (must run on `q`)

    private struct Row { var candidates: [LyricsResult]; var selected: Int; var offsetMs: Int }

    private func rawRow(_ trackId: String) -> Row? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT candidates, selected, offset_ms FROM lyrics WHERE track_id=?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        bindText(stmt, 1, trackId)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        let json = String(cString: c)
        guard let data = json.data(using: .utf8),
              let cands = try? decoder.decode([LyricsResult].self, from: data) else { return nil }
        return Row(candidates: cands, selected: Int(sqlite3_column_int(stmt, 1)), offsetMs: Int(sqlite3_column_int(stmt, 2)))
    }

    private func rejectedSet(_ trackId: String) -> Set<String> {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT fingerprint FROM rejected WHERE track_id=?;", -1, &stmt, nil) == SQLITE_OK else { return [] }
        bindText(stmt, 1, trackId)
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.insert(String(cString: c)) }
        }
        return out
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
    }
}
