import Foundation

/// Parser for LRC-format synced lyrics.
///
/// Handles lines like:
///   [00:12.34] some text
///   [00:12.340] some text          (millisecond precision)
///   [00:12.34][00:48.10] repeated  (multiple timestamps per line)
///   [ti:Title] / [ar:Artist] ...   (metadata — ignored)
enum LRC {
    static func parse(_ raw: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let tag = try! NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)

        for rawLine in raw.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let ns = line as NSString
            let matches = tag.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }

            // Text is whatever follows the final timestamp tag on this line.
            let lastEnd = matches.last!.range.location + matches.last!.range.length
            let text = ns.substring(from: lastEnd).trimmingCharacters(in: .whitespaces)

            for m in matches {
                let mm = Int(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Int(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0
                if m.range(at: 3).location != NSNotFound {
                    let fs = ns.substring(with: m.range(at: 3))
                    // Normalise 2- or 3-digit fractions to milliseconds.
                    if fs.count == 2 { frac = (Int(fs) ?? 0) * 10 }
                    else if fs.count == 1 { frac = (Int(fs) ?? 0) * 100 }
                    else { frac = Int(fs) ?? 0 }
                }
                let timeMs = (mm * 60 + ss) * 1000 + frac
                out.append(LyricLine(timeMs: timeMs, text: text))
            }
        }
        out.sort { $0.timeMs < $1.timeMs }
        return out
    }
}
