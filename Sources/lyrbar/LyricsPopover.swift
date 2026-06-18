import AppKit

/// A single clickable lyric line in the popover. Clicking seeks playback.
private final class LyricRowView: NSView {
    let timeMs: Int
    let label = NSTextField(labelWithString: "")
    var onClick: ((Int) -> Void)?

    init(line: LyricLine) {
        self.timeMs = line.timeMs
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = line.text.isEmpty ? "♪" : line.text
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 380
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setActive(_ active: Bool) {
        label.textColor = active ? .labelColor : .secondaryLabelColor
        label.font = active ? .boldSystemFont(ofSize: 15) : .systemFont(ofSize: 13)
    }

    override func mouseDown(with event: NSEvent) { onClick?(timeMs) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Top-down coordinates so scroll-to-line math is intuitive.
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// A slim playback progress bar that can also be clicked/dragged to seek.
private final class ProgressBarView: NSView {
    var fraction: CGFloat = 0 { didSet { needsLayout = true } }
    var onScrub: ((CGFloat) -> Void)?
    private let track = CALayer()
    private let fill = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        track.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.4).cgColor
        fill.backgroundColor = AppAccentColor.current.cgColor
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let h: CGFloat = 4
        let y = (bounds.height - h) / 2
        track.frame = CGRect(x: 0, y: y, width: bounds.width, height: h)
        track.cornerRadius = h / 2
        let w = bounds.width * max(0, min(1, fraction))
        fill.frame = CGRect(x: 0, y: y, width: w, height: h)
        fill.cornerRadius = h / 2
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { scrub(event) }
    override func mouseDragged(with event: NSEvent) { scrub(event) }
    private func scrub(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0 else { return }
        onScrub?(max(0, min(1, p.x / bounds.width)))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

@MainActor
final class LyricsPopoverController: NSViewController {
    static let contentSize = NSSize(width: 420, height: 520)

    private weak var engine: LyricsEngine?
    var onSeek: ((Int) -> Void)?           // absolute playback position (ms)
    var onNextMatch: (() -> Void)?
    var onProviderChange: ((LyricsProviderKind) -> Void)?
    var onWidthChange: ((Double) -> Void)?
    var onOffsetChange: ((Int) -> Void)?
    var onTrash: (() -> Void)?
    var onResume: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onShowDevices: ((NSView) -> Void)?   // anchor view for the device picker
    var onShowSettings: ((NSView) -> Void)?
    var onQuit: (() -> Void)?

    // Header
    private let artwork = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "lyrbar")
    private let artistLabel = NSTextField(labelWithString: "")
    private let sourceLabel = NSTextField(labelWithString: "")

    // Transport + progress
    private let prevButton = NSButton()
    private let playPauseButton = NSButton()
    private let nextTrackButton = NSButton()
    private let progressBar = ProgressBarView()
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let durationLabel = NSTextField(labelWithString: "0:00")
    private lazy var transportRow = NSStackView()
    private lazy var progressRow = NSStackView()

    // Lyrics
    private let scrollView = NSScrollView()
    private let stack = FlippedStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var rows: [LyricRowView] = []

    // Up next
    private let upNextIcon = NSImageView()
    private let upNextLabel = NSTextField(labelWithString: "")
    private lazy var upNextRow = NSStackView()

    // Footer controls
    private let nextButton = NSButton()
    private let trashButton = NSButton()
    private let deviceButton = NSButton()
    private let settingsButton = NSButton()
    private let quitButton = NSButton()
    private let resumeButton = NSButton(title: "▶︎ Resume syncing", target: nil, action: nil)
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var widthSlider: SliderItemView!
    private var offsetSlider: SliderItemView!

    private var artURLLoaded: String?
    private var refreshTimer: Timer?
    private static let placeholder: NSImage? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .light)
        return NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }()

    init(engine: LyricsEngine) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    override func loadView() {
        preferredContentSize = Self.contentSize
        let root = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))

        // ---- Header: artwork + title/artist/source ----
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 8
        artwork.layer?.masksToBounds = true
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.image = Self.placeholder
        artwork.contentTintColor = .tertiaryLabelColor
        root.addSubview(artwork)

        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        artistLabel.font = .systemFont(ofSize: 12)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.translatesAutoresizingMaskIntoConstraints = false
        artistLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourceLabel.font = .systemFont(ofSize: 10)
        sourceLabel.textColor = .tertiaryLabelColor
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.translatesAutoresizingMaskIntoConstraints = false
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleStack = NSStackView(views: [titleLabel, artistLabel, sourceLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleStack)

        // ---- Transport ----
        configureTransport(prevButton, symbol: "backward.fill", size: 13, action: #selector(prevTapped))
        configureTransport(playPauseButton, symbol: "play.fill", size: 19, action: #selector(playPauseTapped))
        configureTransport(nextTrackButton, symbol: "forward.fill", size: 13, action: #selector(nextTrackTapped))
        transportRow = NSStackView(views: [prevButton, playPauseButton, nextTrackButton])
        transportRow.orientation = .horizontal
        transportRow.spacing = 26
        transportRow.alignment = .centerY
        transportRow.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(transportRow)

        // ---- Progress ----
        for l in [elapsedLabel, durationLabel] {
            l.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            l.textColor = .tertiaryLabelColor
        }
        durationLabel.alignment = .right
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.onScrub = { [weak self] frac in
            guard let self, let np = self.engine?.nowPlaying, np.durationMs > 0 else { return }
            self.onSeek?(Int(frac * CGFloat(np.durationMs)))
        }
        progressRow = NSStackView(views: [elapsedLabel, progressBar, durationLabel])
        progressRow.orientation = .horizontal
        progressRow.spacing = 8
        progressRow.alignment = .centerY
        progressRow.translatesAutoresizingMaskIntoConstraints = false
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)
        root.addSubview(progressRow)

        let topDivider = NSBox(); topDivider.boxType = .separator
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(topDivider)

        // ---- Lyrics ----
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = stack
        root.addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)

        resumeButton.bezelStyle = .rounded
        resumeButton.target = self
        resumeButton.action = #selector(resumeTapped)
        resumeButton.isHidden = true
        resumeButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(resumeButton)

        let bottomDivider = NSBox(); bottomDivider.boxType = .separator
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bottomDivider)

        let controls = buildControls()
        controls.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(controls)

        NSLayoutConstraint.activate([
            artwork.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            artwork.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            artwork.widthAnchor.constraint(equalToConstant: 52),
            artwork.heightAnchor.constraint(equalToConstant: 52),

            titleStack.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 12),
            titleStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            titleStack.centerYAnchor.constraint(equalTo: artwork.centerYAnchor),

            transportRow.topAnchor.constraint(equalTo: artwork.bottomAnchor, constant: 12),
            transportRow.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            progressRow.topAnchor.constraint(equalTo: transportRow.bottomAnchor, constant: 10),
            progressRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            progressRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            topDivider.topAnchor.constraint(equalTo: progressRow.bottomAnchor, constant: 10),
            topDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            topDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: topDivider.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor, constant: -6),

            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -28),

            resumeButton.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            resumeButton.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 12),

            bottomDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            bottomDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            bottomDivider.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -4),

            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        self.view = root
    }

    private func configureTransport(_ b: NSButton, symbol: String, size: CGFloat, action: Selector) {
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = .labelColor
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
    }

    private func buildControls() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8
        container.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)

        // ---- Up next preview ----
        let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        upNextIcon.image = NSImage(systemSymbolName: "forward.end",
                                   accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        upNextIcon.contentTintColor = .tertiaryLabelColor
        upNextIcon.setContentHuggingPriority(.required, for: .horizontal)
        upNextLabel.font = .systemFont(ofSize: 11)
        upNextLabel.textColor = .secondaryLabelColor
        upNextLabel.lineBreakMode = .byTruncatingTail
        upNextRow = NSStackView(views: [upNextIcon, upNextLabel])
        upNextRow.orientation = .horizontal
        upNextRow.spacing = 5
        upNextRow.alignment = .centerY
        upNextRow.isHidden = true
        container.addArrangedSubview(upNextRow)

        // ---- Icon action row ----
        configureIconButton(nextButton, symbol: "arrow.triangle.2.circlepath",
                            action: #selector(nextTapped),
                            tip: "Show a different lyrics match")
        configureIconButton(trashButton, symbol: "trash",
                            action: #selector(trashTapped),
                            tip: "Throw out these lyrics as a wrong match (won't show again)")
        configureIconButton(deviceButton, symbol: "airplayaudio",
                            action: #selector(deviceTapped),
                            tip: "Switch playback device")
        configureIconButton(settingsButton, symbol: "gearshape",
                            action: #selector(settingsTapped),
                            tip: "Settings")
        configureIconButton(quitButton, symbol: "power",
                            action: #selector(quitTapped),
                            tip: "Quit lyrbar")

        providerPopup.controlSize = .small
        providerPopup.font = .systemFont(ofSize: 11)
        providerPopup.removeAllItems()
        providerPopup.addItems(withTitles: LyricsProviderKind.allCases.map(\.display))
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [nextButton, trashButton, deviceButton, spacer, settingsButton, quitButton])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        container.addArrangedSubview(row)

        widthSlider = SliderItemView(title: "Menu bar width",
                                     range: Settings.widthRange,
                                     value: Settings.shared.width,
                                     format: { "\(Int($0)) px" })
        widthSlider.onChange = { [weak self] v in self?.onWidthChange?(v) }

        offsetSlider = SliderItemView(title: "Lyric offset (this song)",
                                      range: Settings.offsetRange,
                                      value: Double(engine?.currentOffsetMs ?? 0),
                                      format: { String(format: "%+d ms", Int($0)) })
        offsetSlider.onChange = { [weak self] v in self?.onOffsetChange?(Int(v)) }

        for v in [upNextRow as NSView, row as NSView] {
            v.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -28).isActive = true
        }
        return container
    }

    /// A borderless SF-Symbol button used in the footer action row.
    private func configureIconButton(_ b: NSButton, symbol: String, action: Selector, tip: String) {
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = .secondaryLabelColor
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(cfg)
        b.target = self
        b.action = action
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// Update the "Up next" footer preview (nil hides the row).
    func updateUpNext(_ upNext: UpNext?) {
        guard isViewLoaded else { return }
        if let upNext {
            upNextLabel.stringValue = "Up next · \(upNext.title) — \(upNext.artist)"
            upNextRow.isHidden = false
        } else {
            upNextRow.isHidden = true
        }
    }

    // MARK: Appearance lifecycle — drive the live progress/transport refresh.

    override func viewWillAppear() {
        super.viewWillAppear()
        startRefresh()
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        stopRefresh()
    }

    private func startRefresh() {
        stopRefresh()
        updateTransport()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTransport() }
        }
    }
    private func stopRefresh() {
        refreshTimer?.invalidate(); refreshTimer = nil
    }

    private func updateTransport() {
        guard isViewLoaded, let engine else { return }
        let np = engine.nowPlaying
        let active = (np != nil) && !engine.isSuspended
        transportRow.isHidden = !active
        progressRow.isHidden = !active

        let playing = np?.isPlaying ?? false
        let cfg = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        playPauseButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill",
                                        accessibilityDescription: nil)?.withSymbolConfiguration(cfg)

        if let np, np.durationMs > 0 {
            let pos = max(0, min(engine.playbackPosition(), np.durationMs))
            progressBar.fraction = CGFloat(pos) / CGFloat(np.durationMs)
            elapsedLabel.stringValue = Self.mmss(pos)
            durationLabel.stringValue = Self.mmss(np.durationMs)
        } else {
            progressBar.fraction = 0
            elapsedLabel.stringValue = "0:00"
            durationLabel.stringValue = "0:00"
        }
    }

    private static func mmss(_ ms: Int) -> String {
        let s = max(0, ms) / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func truncate(_ text: String, toWidth width: CGFloat, font: NSFont) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard (text as NSString).size(withAttributes: attributes).width > width else { return text }
        var low = 0
        var high = text.count
        var best = "..."
        while low <= high {
            let mid = (low + high) / 2
            let candidate = String(text.prefix(mid)) + "..."
            if (candidate as NSString).size(withAttributes: attributes).width <= width {
                best = candidate
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

    // MARK: Reload

    /// Rebuild the line list from the engine's current candidate.
    func reload() {
        guard isViewLoaded, let engine else { return }
        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }

        providerPopup.selectItem(at: LyricsProviderKind.allCases.firstIndex(of: Settings.shared.provider) ?? 0)
        widthSlider.setValue(Settings.shared.width)
        offsetSlider.setValue(Double(engine.currentOffsetMs))
        offsetSlider.isEnabled = engine.nowPlaying != nil
        nextButton.isEnabled = engine.candidates.count > 1
        trashButton.isEnabled = engine.current != nil
        updateUpNext(engine.isSuspended ? nil : engine.upNext)
        updateTransport()

        if engine.isSuspended {
            titleLabel.stringValue = "Paused"
            artistLabel.stringValue = ""
            sourceLabel.stringValue = ""
            artwork.image = Self.placeholder
            artURLLoaded = nil
            scrollView.isHidden = true
            emptyLabel.isHidden = false
            emptyLabel.stringValue = "Syncing paused after 10 minutes idle."
            resumeButton.isHidden = false
            return
        }
        resumeButton.isHidden = true

        if let np = engine.nowPlaying {
            titleLabel.stringValue = Self.truncate(np.title, toWidth: 328, font: titleLabel.font ?? .systemFont(ofSize: 15, weight: .bold))
            titleLabel.toolTip = np.title
            artistLabel.stringValue = np.artist
            sourceLabel.stringValue = engine.current.map { c in
                c.synced ? "\(c.source) · synced" : "\(c.source) · text only"
            } ?? ""
            loadArtwork(np.artworkURL)
        } else {
            titleLabel.stringValue = "Nothing playing"
            titleLabel.toolTip = nil
            artistLabel.stringValue = ""
            sourceLabel.stringValue = ""
            artwork.image = Self.placeholder
            artURLLoaded = nil
        }

        let lines = engine.lines
        if lines.isEmpty {
            if let plain = engine.current?.plain, engine.current?.synced == false {
                scrollView.isHidden = false
                emptyLabel.isHidden = true
                let row = LyricRowView(line: LyricLine(timeMs: 0, text: plain))
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                rows.append(row)
            } else {
                scrollView.isHidden = true
                emptyLabel.isHidden = false
                if engine.nowPlaying == nil {
                    emptyLabel.stringValue = "Play something in Spotify…"
                } else if engine.isLoadingLyrics {
                    emptyLabel.stringValue = "Loading lyrics…"
                } else {
                    emptyLabel.stringValue = "No lyrics found.\nTap “Next match” or switch provider below."
                }
            }
            return
        }

        scrollView.isHidden = false
        emptyLabel.isHidden = true
        for line in lines {
            let row = LyricRowView(line: line)
            row.onClick = { [weak self] t in
                self?.onSeek?(max(0, t - (self?.engine?.currentOffsetMs ?? 0)))
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rows.append(row)
        }
        highlight(engine.currentLineIndex)
    }

    func highlight(_ index: Int?) {
        guard isViewLoaded else { return }
        for (i, row) in rows.enumerated() { row.setActive(i == index) }
        guard let index, rows.indices.contains(index) else { return }
        // Force a layout pass first: when the popover has just opened, the stack
        // and clip view haven't been laid out yet, so their frames are still
        // zero/stale and the scroll math below would clamp to the top. Resolving
        // layout up front makes "open on the current line" land correctly.
        view.layoutSubtreeIfNeeded()
        let row = rows[index]
        let target = row.frame.midY - scrollView.contentView.bounds.height / 2
        let maxY = max(0, stack.frame.height - scrollView.contentView.bounds.height)
        let y = min(max(0, target), maxY)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func loadArtwork(_ urlStr: String?) {
        guard let urlStr else {
            artwork.image = Self.placeholder
            artURLLoaded = nil
            return
        }
        guard urlStr != artURLLoaded else { return }
        artURLLoaded = urlStr
        artwork.image = Self.placeholder
        guard let url = URL(string: urlStr) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.artURLLoaded == urlStr else { return }
                self.artwork.image = img
            }
        }.resume()
    }

    // MARK: Actions

    @objc private func nextTapped() { onNextMatch?() }
    @objc private func trashTapped() { onTrash?() }
    @objc private func deviceTapped() { onShowDevices?(deviceButton) }
    @objc private func quitTapped() { onQuit?() }
    @objc private func resumeTapped() { onResume?() }
    @objc private func prevTapped() { onPrevious?() }
    @objc private func playPauseTapped() { onPlayPause?() }
    @objc private func nextTrackTapped() { onNext?() }
    @objc private func settingsTapped() { onShowSettings?(settingsButton) }

    @objc private func providerChanged() {
        let idx = providerPopup.indexOfSelectedItem
        guard LyricsProviderKind.allCases.indices.contains(idx) else { return }
        onProviderChange?(LyricsProviderKind.allCases[idx])
    }
}
