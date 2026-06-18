import Foundation

/// A snapshot of Spotify playback at a point in time.
struct NowPlaying: Equatable {
    var trackId: String
    var title: String
    var artist: String
    var album: String
    var durationMs: Int
    var progressMs: Int
    var isPlaying: Bool
    /// Album artwork URL (for the popover header); nil when unavailable.
    var artworkURL: String?
    /// Monotonic timestamp captured when this snapshot was fetched, used to
    /// extrapolate the current position between polls.
    var capturedAt: TimeInterval

    var query: TrackQuery {
        TrackQuery(title: title, artist: artist, album: album, durationSec: durationMs / 1000)
    }
}

struct TrackQuery {
    var title: String
    var artist: String
    var album: String
    var durationSec: Int
}

struct LyricLine: Codable {
    var timeMs: Int
    var text: String
}

/// One candidate set of lyrics from some provider. `lines` empty == plain only.
struct LyricsResult: Codable {
    var lines: [LyricLine]
    var plain: String?
    var source: String      // "LRCLIB" / "NetEase"
    var label: String       // human-friendly description for the candidate menu
    var synced: Bool { !lines.isEmpty }

    /// Stable identity for a candidate, used to remember trashed (wrong) matches.
    var fingerprint: String {
        let head = lines.prefix(3).map(\.text).joined(separator: "|")
        return "\(source)#\(lines.count)#\(head.prefix(80))"
    }
}
