import Foundation

@MainActor
protocol LyricsEngineDelegate: AnyObject {
    func engineDidUpdateStatusText(_ text: String)
    func engineDidLoadLyrics()                 // candidate set changed → rebuild popover
    func engineDidChangeCurrentLine(_ index: Int?)
    func engineDidUpdateUpNext(_ upNext: UpNext?)   // queue preview changed
}

/// A lightweight preview of the next track in the playback queue.
struct UpNext: Equatable {
    var title: String
    var artist: String
}

/// Drives the poll → extrapolate → highlight loop.
@MainActor
final class LyricsEngine {
    weak var delegate: LyricsEngineDelegate?

    private let client: SpotifyClient
    private let store = LyricsStore.shared
    init(client: SpotifyClient) { self.client = client }

    private(set) var nowPlaying: NowPlaying?
    private(set) var candidates: [LyricsResult] = []
    private(set) var candidateIndex = 0
    private(set) var currentLineIndex: Int?
    private(set) var isLoadingLyrics = false
    private(set) var isSuspended = false
    /// Lyric timing offset for the *current* track (ms), loaded from / saved to
    /// the store per song. Positive = show lyrics earlier.
    private(set) var currentOffsetMs = 0
    var effectiveOffsetMs: Int { Settings.shared.globalOffsetMs + currentOffsetMs }
    /// The next track in the Spotify queue, for the popover's "Up next" preview.
    private(set) var upNext: UpNext?

    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var lyricsFetchTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var fetchGeneration = 0
    private var lastStatusText = ""
    private var running = false
    private var inFlightPrefetch: Set<String> = []

    // Auto-suspend after this long with playback stopped/paused.
    private let idleLimit: TimeInterval = 600   // 10 minutes
    private let idlePollInterval: TimeInterval = 120
    private let activeTickInterval: TimeInterval = 0.2
    private var notPlayingSince: TimeInterval?

    var current: LyricsResult? {
        candidates.indices.contains(candidateIndex) ? candidates[candidateIndex] : nil
    }
    var lines: [LyricLine] { current?.lines ?? [] }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        isSuspended = false
        notPlayingSince = nil
        scheduleTimers()
        Task { await poll() }
    }

    func stop() {
        running = false
        isSuspended = false
        notPlayingSince = nil
        lyricsFetchTask?.cancel()
        lyricsFetchTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        inFlightPrefetch.removeAll()
        invalidateTimers()
        nowPlaying = nil
        candidates = []
        currentLineIndex = nil
        upNext = nil
    }

    /// Back off after a long idle, but keep a slow poll alive so playback can
    /// wake syncing up automatically.
    private func suspend() {
        invalidateTimers()
        isSuspended = true
        notPlayingSince = nil
        pollTimer = Timer.scheduledTimer(withTimeInterval: idlePollInterval, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
        setStatus("⏸ lyrbar paused — click to resume")
        delegate?.engineDidLoadLyrics()
    }

    /// Manually resume syncing (from the menu / popover).
    func resume() {
        guard running else { return }
        isSuspended = false
        notPlayingSince = nil
        scheduleTimers()
        delegate?.engineDidLoadLyrics()
        Task { await poll() }
    }

    private func scheduleTimers() {
        invalidateTimers()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Double(Settings.shared.pollMs) / 1000.0,
                                         repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: activeTickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func invalidateTimers() {
        pollTimer?.invalidate(); pollTimer = nil
        tickTimer?.invalidate(); tickTimer = nil
    }

    // MARK: Polling

    private func poll() async {
        do {
            let np = try await client.currentlyPlaying()
            apply(np)
        } catch let e as AuthError {
            setStatus("⚠︎ \(e.localizedDescription)")
        } catch {
            // transient network/API hiccup — keep last good display
        }
    }

    private func apply(_ np: NowPlaying?) {
        // Idle tracking → auto-suspend after `idleLimit` of no active playback.
        let playing = (np?.isPlaying == true)
        if playing {
            if isSuspended {
                isSuspended = false
                scheduleTimers()
                delegate?.engineDidLoadLyrics()
            }
            notPlayingSince = nil
        } else {
            let now = ProcessInfo.processInfo.systemUptime
            if let since = notPlayingSince {
                if now - since >= idleLimit { suspend(); return }
            } else {
                notPlayingSince = now
            }
        }

        guard let np else {
            nowPlaying = nil
            candidates = []
            currentLineIndex = nil
            updateUpNext(from: nil)
            setStatus("♪ lyrbar — nothing playing")
            delegate?.engineDidLoadLyrics()
            return
        }
        let trackChanged = (np.trackId != nowPlaying?.trackId)
        nowPlaying = np
        if trackChanged {
            candidates = []
            candidateIndex = 0
            currentLineIndex = nil
            upNext = nil   // refreshed by the next queue read; avoid showing a stale entry
            setStatus("♪ \(np.title) — \(np.artist)")
            delegate?.engineDidLoadLyrics()
            fetchLyrics(for: np)
        }
        tick()
    }

    // MARK: Lyrics fetch (store-backed)

    private func fetchLyrics(for np: NowPlaying, force: Bool = false) {
        lyricsFetchTask?.cancel()
        fetchGeneration += 1
        let gen = fetchGeneration
        let kind = Settings.shared.provider
        let query = np.query
        // Per-song offset travels with the track.
        currentOffsetMs = store.offset(np.trackId)

        // Instant path: lyrics already in the persistent library.
        if !force, let entry = store.entry(for: np.trackId) {
            candidates = entry.candidates
            candidateIndex = min(max(0, entry.selected), candidates.count - 1)
            currentLineIndex = nil
            isLoadingLyrics = false
            delegate?.engineDidLoadLyrics()
            tick()
            prefetchUpcoming(kind: kind)
            return
        }

        isLoadingLyrics = true
        candidates = []
        candidateIndex = 0
        currentLineIndex = nil
        delegate?.engineDidLoadLyrics()

        lyricsFetchTask = Task {
            var results = await LyricsService.resolve(query, kind: kind)
            guard !Task.isCancelled, gen == fetchGeneration, nowPlaying?.trackId == np.trackId else { return }
            let rejected = store.rejected(np.trackId)
            results = results.filter { !rejected.contains($0.fingerprint) }
            candidates = results
            candidateIndex = 0
            currentLineIndex = nil
            isLoadingLyrics = false
            store.upsert(trackId: np.trackId, query: query, candidates: results, selected: 0)
            delegate?.engineDidLoadLyrics()
            tick()
            prefetchUpcoming(kind: kind)
        }
    }

    private func prefetchUpcoming(kind: LyricsProviderKind) {
        prefetchTask?.cancel()
        inFlightPrefetch.removeAll()
        prefetchTask = Task {
            let upcoming = (try? await client.upcoming(limit: 3)) ?? []
            guard !Task.isCancelled, running else { return }
            updateUpNext(from: upcoming.first)
            for track in upcoming where !store.hasLyrics(track.id) && !inFlightPrefetch.contains(track.id) {
                inFlightPrefetch.insert(track.id)
                let res = await LyricsService.resolve(track.query, kind: kind)
                guard !Task.isCancelled, running else {
                    inFlightPrefetch.remove(track.id)
                    return
                }
                let rejected = store.rejected(track.id)
                let filtered = res.filter { !rejected.contains($0.fingerprint) }
                inFlightPrefetch.remove(track.id)
                if !filtered.isEmpty {
                    store.upsert(trackId: track.id, query: track.query, candidates: filtered, selected: 0)
                }
            }
        }
    }

    private func updateUpNext(from track: SpotifyClient.QueuedTrack?) {
        let next = track.map { UpNext(title: $0.query.title, artist: $0.query.artist) }
        guard next != upNext else { return }
        upNext = next
        delegate?.engineDidUpdateUpNext(next)
    }

    // MARK: Extrapolation + highlight

    /// Estimated playback position in ms, including the user offset.
    func position() -> Int {
        guard let np = nowPlaying else { return 0 }
        var pos = np.progressMs
        if np.isPlaying {
            let elapsed = (ProcessInfo.processInfo.systemUptime - np.capturedAt) * 1000.0
            pos += Int(elapsed)
        }
        return pos + effectiveOffsetMs
    }

    /// True playback position (no lyric offset) — for the transport/progress UI.
    func playbackPosition() -> Int { position() - effectiveOffsetMs }

    /// Current lyric line's display window in the same timeline as `position()`.
    /// The UI uses this to pace overflow scrolling without owning lyric timing.
    func currentLineDisplayWindow() -> (startMs: Int, endMs: Int)? {
        guard
            let np = nowPlaying,
            let idx = currentLineIndex,
            lines.indices.contains(idx)
        else { return nil }

        let startMs = lines[idx].timeMs
        let endMs: Int
        if lines.indices.contains(idx + 1) {
            endMs = lines[idx + 1].timeMs
        } else {
            endMs = np.durationMs + effectiveOffsetMs
        }
        guard endMs > startMs else { return nil }
        return (startMs, endMs)
    }

    /// Force an immediate poll (e.g. right after a transport command) so the UI
    /// reflects the new playback state without waiting for the next tick.
    func nudge() { Task { await poll() } }

    private func tick() {
        guard let np = nowPlaying else { return }
        let lines = self.lines

        guard !lines.isEmpty else {
            if isLoadingLyrics {
                setStatus("♪ \(np.title) — \(np.artist)  (loading…)")
            } else if current?.plain != nil, current?.synced == false {
                setStatus("♪ \(np.title) — \(np.artist)  (no synced lyrics)")
            } else {
                setStatus("♪ \(np.title) — \(np.artist)")
            }
            return
        }

        let pos = position()
        let idx = currentIndex(for: pos, in: lines)
        if idx != currentLineIndex {
            currentLineIndex = idx
            delegate?.engineDidChangeCurrentLine(idx)
        }
        if let idx, lines.indices.contains(idx) {
            let text = lines[idx].text.isEmpty ? "♪" : lines[idx].text
            setStatus(text)
        } else {
            setStatus("♪ \(np.title)")   // before the first lyric line
        }
    }

    private func currentIndex(for pos: Int, in lines: [LyricLine]) -> Int? {
        guard let first = lines.first, pos >= first.timeMs else { return nil }
        var lo = 0, hi = lines.count - 1, ans = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].timeMs <= pos { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    private func setStatus(_ text: String) {
        guard text != lastStatusText else { return }
        lastStatusText = text
        delegate?.engineDidUpdateStatusText(text)
    }

    // MARK: User actions

    /// Cycle to the next candidate lyric set (when the current one is wrong).
    func cycleCandidate() {
        guard candidates.count > 1 else { return }
        candidateIndex = (candidateIndex + 1) % candidates.count
        currentLineIndex = nil
        if let id = nowPlaying?.trackId { store.setSelected(id, index: candidateIndex) }
        delegate?.engineDidLoadLyrics()
        tick()
    }

    /// Throw out the currently shown (wrong) lyrics permanently, then move on.
    func trashCurrent() {
        guard let np = nowPlaying, let cur = current else { return }
        store.reject(np.trackId, fingerprint: cur.fingerprint)
        candidates.remove(at: candidateIndex)
        if candidateIndex >= candidates.count { candidateIndex = max(0, candidates.count - 1) }
        currentLineIndex = nil
        store.upsert(trackId: np.trackId, query: np.query, candidates: candidates, selected: candidateIndex)
        delegate?.engineDidLoadLyrics()
        tick()
        // Nothing left? Try to find an alternative that isn't rejected.
        if candidates.isEmpty { fetchLyrics(for: np, force: true) }
    }

    /// Set the lyric offset for the current track and persist it per song.
    func setOffset(_ ms: Int) {
        guard let id = nowPlaying?.trackId else { return }
        currentOffsetMs = min(max(ms, -5000), 5000)
        store.setOffset(id, ms: currentOffsetMs)
        tick()
    }

    func setGlobalOffset(_ ms: Int) {
        Settings.shared.globalOffsetMs = ms
        tick()
    }

    func reload() {
        lyricsFetchTask?.cancel()
        prefetchTask?.cancel()
        inFlightPrefetch.removeAll()
        if let np = nowPlaying { fetchLyrics(for: np, force: true) }
    }
}
