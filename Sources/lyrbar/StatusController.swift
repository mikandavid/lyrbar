import AppKit

@MainActor
final class StatusController: NSObject, LyricsEngineDelegate, NSPopoverDelegate {
    private enum MenuLayout {
        static let width: CGFloat = 320
        static let titleWidth: CGFloat = 266
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let auth = SpotifyAuth()
    private lazy var client = SpotifyClient(auth: auth)
    private lazy var engine = LyricsEngine(client: client)

    private let popover = NSPopover()
    private lazy var popoverVC = LyricsPopoverController(engine: engine)

    private let statusClipView = PassthroughClipView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var statusText = "♪ lyrbar"
    private var clickMonitor: Any?
    private var widthRenderTimer: Timer?
    private var scrollTimer: Timer?
    private var scrollState: ScrollState?
    private var isImporting = false
    private let scrollFrameInterval: TimeInterval = 1.0 / 20.0

    private struct ScrollState {
        var text: String
        var font: NSFont
        var visibleWidth: CGFloat
        var textWidth: CGFloat
        var overflowWidth: CGFloat
        var startMs: Int
        var endMs: Int
        var delayMs: Int
        var arriveEarlyMs: Int
    }

    private final class MenuSectionHeaderView: NSView {
        init(_ title: String) {
            super.init(frame: NSRect(x: 0, y: 0, width: MenuLayout.width, height: 24))
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .tertiaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    private final class PassthroughClipView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    // MARK: Start

    func start() {
        engine.delegate = self
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = popoverVC
        popoverVC.onSeek = { [weak self] ms in
            Task { try? await self?.client.seek(toMs: ms) }
        }
        popoverVC.onNextMatch = { [weak self] in self?.engine.cycleCandidate() }
        popoverVC.onProviderChange = { [weak self] kind in
            Settings.shared.provider = kind
            self?.engine.reload()
        }
        popoverVC.onWidthChange = { [weak self] v in
            Settings.shared.width = v
            self?.scheduleWidthRender()
        }
        popoverVC.onTrash = { [weak self] in self?.engine.trashCurrent() }
        popoverVC.onResume = { [weak self] in self?.engine.resume() }
        popoverVC.onOffsetChange = { [weak self] ms in self?.engine.setOffset(ms) }
        popoverVC.onPrevious = { [weak self] in
            Task { await self?.client.previous(); self?.engine.nudge() }
        }
        popoverVC.onNext = { [weak self] in
            Task { await self?.client.next(); self?.engine.nudge() }
        }
        popoverVC.onPlayPause = { [weak self] in
            guard let self else { return }
            let playing = self.engine.nowPlaying?.isPlaying ?? false
            Task {
                if playing { await self.client.pause() } else { await self.client.play() }
                self.engine.nudge()
            }
        }
        popoverVC.onShowDevices = { [weak self] anchor in self?.showDeviceMenu(from: anchor) }
        popoverVC.onShowSettings = { [weak self] anchor in self?.showSettingsMenu(from: anchor) }
        popoverVC.onQuit = { NSApp.terminate(nil) }
        refreshAccountState()
    }

    /// Reflects login state in the bar and starts/stops the engine.
    private func refreshAccountState() {
        if Settings.shared.clientId?.isEmpty != false {
            engine.stop()
            render("♪ lyrbar — click to set up")
        } else if !auth.isLoggedIn {
            engine.stop()
            render("♪ lyrbar — click to log in")
        } else {
            render("♪ lyrbar — connecting…")
            engine.start()
        }
    }

    // MARK: LyricsEngineDelegate

    func engineDidUpdateStatusText(_ text: String) {
        guard !isImporting else { return }   // don't clobber import progress
        render(text)
    }
    func engineDidLoadLyrics() { popoverVC.reload() }
    func engineDidChangeCurrentLine(_ index: Int?) { popoverVC.highlight(index) }
    func engineDidUpdateUpNext(_ upNext: UpNext?) { popoverVC.updateUpNext(upNext) }

    // MARK: Device picker

    /// Fetch Spotify Connect devices and show a picker anchored to `anchor`.
    private func showDeviceMenu(from anchor: NSView) {
        Task {
            let devices = await client.devices()
            let menu = NSMenu()
            menu.minimumWidth = MenuLayout.width
            if devices.isEmpty {
                let mi = NSMenuItem(title: "No devices available", action: nil, keyEquivalent: "")
                mi.isEnabled = false
                menu.addItem(mi)
                menu.addItem(.separator())
                let hint = NSMenuItem(title: fixedMenuTitle("Open Spotify on a device to see it here"),
                                      action: nil, keyEquivalent: "")
                hint.isEnabled = false
                menu.addItem(hint)
            } else {
                let header = NSMenuItem(title: "Play on…", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for d in devices {
                    let mi = NSMenuItem(title: self.fixedMenuTitle(d.name), action: #selector(self.devicePicked(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = d.id
                    mi.state = d.isActive ? .on : .off
                    let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                    mi.image = NSImage(systemSymbolName: d.symbolName, accessibilityDescription: nil)?
                        .withSymbolConfiguration(cfg)
                    menu.addItem(mi)
                }
            }
            // Pop up just below the anchoring button.
            let origin = NSPoint(x: 0, y: anchor.bounds.height + 4)
            menu.popUp(positioning: nil, at: origin, in: anchor)
        }
    }

    @objc private func devicePicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Task { await client.transferPlayback(to: id); try? await Task.sleep(nanoseconds: 400_000_000); engine.nudge() }
    }

    private func showSettingsMenu(from anchor: NSView) {
        let menu = buildMenu()
        let origin = NSPoint(x: 0, y: anchor.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: anchor)
    }

    // MARK: Rendering

    private func render(_ text: String) {
        statusText = text
        guard let button = statusItem.button else { return }
        let font = NSFont.systemFont(ofSize: 13)
        button.font = font
        button.imagePosition = .noImage

        // Nothing actually playing (idle / setup / login / connecting) → collapse
        // to just the note glyph, sized to its content, so the item doesn't hog
        // the menu bar while there are no lyrics to show. The full message stays
        // available as a tooltip.
        if engine.nowPlaying == nil {
            stopScrolling()
            removeStatusLabel()
            button.alignment = .center
            button.title = "♪"
            button.toolTip = text
            if statusItem.length != NSStatusItem.variableLength {
                statusItem.length = NSStatusItem.variableLength
            }
            return
        }

        // Draw through our own clipped label so overflow never bleeds into
        // neighbouring menu bar items.
        button.alignment = .center
        // Fixed width set by the slider; only mutate when it actually changes
        // to avoid menu-bar layout thrash.
        let width = Settings.shared.width
        if statusItem.length != width { statusItem.length = width }
        let visibleWidth = CGFloat(width - 14)
        installStatusLabel(in: button, visibleWidth: visibleWidth, font: font)
        let textWidth = Self.measuredWidth(text, font: font)
        if shouldScroll(text, visibleWidth: visibleWidth, font: font, measuredWidth: textWidth) {
            startScrolling(text, visibleWidth: visibleWidth, font: font)
        } else {
            stopScrolling()
            let fits = textWidth <= visibleWidth
            setStatusLabel(text,
                           visibleWidth: visibleWidth,
                           labelWidth: visibleWidth,
                           x: 0,
                           font: font,
                           alignment: fits ? .center : .left)
        }
        button.toolTip = text
    }

    private func installStatusLabel(in button: NSStatusBarButton, visibleWidth: CGFloat, font: NSFont) {
        button.title = ""
        button.image = nil

        if statusClipView.superview !== button {
            statusClipView.removeFromSuperview()
            statusClipView.wantsLayer = true
            statusClipView.layer?.masksToBounds = true
            button.addSubview(statusClipView)

            statusLabel.isBordered = false
            statusLabel.isEditable = false
            statusLabel.isSelectable = false
            statusLabel.drawsBackground = false
            statusLabel.maximumNumberOfLines = 1
            statusLabel.textColor = .labelColor
            statusClipView.addSubview(statusLabel)
        }

        let height = max(button.bounds.height, 22)
        statusClipView.frame = NSRect(x: 7, y: 0, width: visibleWidth, height: height)
        statusLabel.font = font
    }

    private func removeStatusLabel() {
        statusClipView.removeFromSuperview()
    }

    private func setStatusLabel(_ text: String,
                                visibleWidth: CGFloat,
                                labelWidth: CGFloat,
                                x: CGFloat,
                                font: NSFont,
                                alignment: NSTextAlignment) {
        let height = max(statusClipView.bounds.height, 22)
        statusLabel.font = font
        statusLabel.stringValue = text
        statusLabel.alignment = alignment
        statusLabel.lineBreakMode = labelWidth <= visibleWidth ? .byTruncatingTail : .byClipping
        statusLabel.cell?.lineBreakMode = statusLabel.lineBreakMode

        let labelHeight = ceil(statusLabel.intrinsicContentSize.height)
        statusLabel.frame = NSRect(
            x: x,
            y: floor((height - labelHeight) / 2),
            width: max(visibleWidth, labelWidth),
            height: labelHeight
        )
    }

    private func shouldScroll(_ text: String, visibleWidth: CGFloat, font: NSFont, measuredWidth: CGFloat) -> Bool {
        guard Settings.shared.scrollLongLines else { return false }
        guard
            let idx = engine.currentLineIndex,
            engine.lines.indices.contains(idx),
            text == (engine.lines[idx].text.isEmpty ? "♪" : engine.lines[idx].text),
            measuredWidth > visibleWidth
        else { return false }
        return engine.currentLineDisplayWindow() != nil
    }

    private func startScrolling(_ text: String, visibleWidth: CGFloat, font: NSFont) {
        guard statusItem.button != nil, let window = engine.currentLineDisplayWindow() else { return }
        let textWidth = Self.measuredWidth(text, font: font)
        let lineDurationMs = max(1, window.endMs - window.startMs)
        let delayMs = min(750, max(200, Int(Double(lineDurationMs) * 0.18)))
        let arriveEarlyMs = min(450, max(150, Int(Double(lineDurationMs) * 0.12)))
        let trailingPad: CGFloat = 12

        scrollState = ScrollState(
            text: text,
            font: font,
            visibleWidth: visibleWidth,
            textWidth: textWidth + trailingPad,
            overflowWidth: textWidth - visibleWidth + trailingPad,
            startMs: window.startMs,
            endMs: window.endMs,
            delayMs: delayMs,
            arriveEarlyMs: arriveEarlyMs
        )
        setStatusLabel(text,
                       visibleWidth: visibleWidth,
                       labelWidth: textWidth + trailingPad,
                       x: 0,
                       font: font,
                       alignment: .left)
        scrollTimer?.invalidate()
        scrollTimer = Timer.scheduledTimer(withTimeInterval: scrollFrameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderScrollFrame() }
        }
    }

    private func stopScrolling() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        scrollState = nil
    }

    private func renderScrollFrame() {
        guard let state = scrollState else { return }
        let pos = engine.position()
        let scrollStartMs = state.startMs + state.delayMs
        let scrollEndMs = max(scrollStartMs + 1, state.endMs - state.arriveEarlyMs)
        let progress: Double
        if pos <= scrollStartMs {
            progress = 0
        } else {
            progress = min(1, Double(pos - scrollStartMs) / Double(scrollEndMs - scrollStartMs))
        }
        let offset = state.overflowWidth * CGFloat(progress)
        var frame = statusLabel.frame
        frame.origin.x = -offset
        statusLabel.frame = frame
        if progress >= 1 {
            scrollTimer?.invalidate()
            scrollTimer = nil
        }
    }

    private func scheduleWidthRender() {
        widthRenderTimer?.invalidate()
        widthRenderTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.widthRenderTimer = nil
                self.render(self.statusText)
            }
        }
    }

    private static func measuredWidth(_ s: String, font: NSFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return (s as NSString).size(withAttributes: attrs).width
    }

    // MARK: Click handling

    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        let isMenuClick = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        // If not usable yet, any click goes to setup/login.
        let needsSetup = Settings.shared.clientId?.isEmpty != false || !auth.isLoggedIn
        if isMenuClick || needsSetup {
            showMenu()
        } else if engine.isSuspended {
            engine.resume()   // a click counts as manually continuing
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            // show() loads the content view; populate afterwards.
            popover.contentSize = LyricsPopoverController.contentSize
            popoverVC.preferredContentSize = LyricsPopoverController.contentSize
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            popover.contentSize = LyricsPopoverController.contentSize
            popoverVC.reload()
            popoverVC.highlight(engine.currentLineIndex)
            NSApp.activate(ignoringOtherApps: true)
            installClickMonitor()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        removeClickMonitor()
    }

    private func installClickMonitor() {
        removeClickMonitor()
        // Clicks in *other* apps (incl. the desktop / another menu bar item)
        // don't always reach a transient popover from an accessory app.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func removeClickMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    func popoverDidClose(_ notification: Notification) { removeClickMonitor() }

    private func showMenu() {
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // restore custom click handling
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.minimumWidth = MenuLayout.width
        let hasClient = Settings.shared.clientId?.isEmpty == false
        let loggedIn = auth.isLoggedIn

        if let np = engine.nowPlaying {
            let header = NSMenuItem(title: fixedMenuTitle("\(np.title) — \(np.artist)"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }

        if hasClient && loggedIn {
            menu.addItem(section("Playback"))
            if engine.isSuspended {
                menu.addItem(item("Resume syncing", #selector(menuResume), symbol: "play.fill"))
            }
            menu.addItem(item("Show full lyrics", #selector(menuShowLyrics), symbol: "text.alignleft"))
            menu.addItem(item("Try next match", #selector(menuNextMatch),
                              enabled: engine.candidates.count > 1,
                              symbol: "arrow.triangle.2.circlepath"))
            menu.addItem(item("Trash these lyrics (wrong match)", #selector(menuTrash),
                              enabled: engine.current != nil,
                              symbol: "trash"))
            menu.addItem(item("Reload lyrics", #selector(menuReload), symbol: "arrow.clockwise"))
            menu.addItem(.separator())

            menu.addItem(section("Timing"))
            let globalOffset = SliderItemView(title: "Global lyric offset",
                                              range: Settings.offsetRange,
                                              value: Double(Settings.shared.globalOffsetMs),
                                              width: MenuLayout.width,
                                              format: { String(format: "%+d ms", Int($0)) })
            globalOffset.onChange = { [weak self] in self?.engine.setGlobalOffset(Int($0)) }
            menu.addItem(viewItem(globalOffset))

            let songOffset = SliderItemView(title: "This song offset",
                                            range: Settings.offsetRange,
                                            value: Double(engine.currentOffsetMs),
                                            width: MenuLayout.width,
                                            format: { String(format: "%+d ms", Int($0)) })
            songOffset.onChange = { [weak self] in self?.engine.setOffset(Int($0)) }
            songOffset.isEnabled = engine.nowPlaying != nil
            menu.addItem(viewItem(songOffset))
            menu.addItem(item("Reset this song offset", #selector(menuResetOffset),
                              enabled: engine.nowPlaying != nil,
                              symbol: "arrow.uturn.backward"))
            menu.addItem(item("Reset global offset", #selector(menuResetGlobalOffset),
                              enabled: Settings.shared.globalOffsetMs != 0,
                              symbol: "arrow.counterclockwise"))
            menu.addItem(.separator())

            menu.addItem(section("Display"))
            let widthSlider = SliderItemView(title: "Menu bar width",
                                             range: Settings.widthRange,
                                             value: Settings.shared.width,
                                             width: MenuLayout.width,
                                             format: { "\(Int($0)) px" })
            widthSlider.onChange = { [weak self] v in
                Settings.shared.width = v
                self?.scheduleWidthRender()
            }
            menu.addItem(viewItem(widthSlider))

            let scrollItem = item("Scroll long menu bar lines",
                                  #selector(menuToggleLongLineScroll),
                                  symbol: "text.alignleft")
            scrollItem.state = Settings.shared.scrollLongLines ? .on : .off
            menu.addItem(scrollItem)

            let providerItem = NSMenuItem(title: fixedMenuTitle("Lyrics provider"), action: nil, keyEquivalent: "")
            providerItem.image = menuImage("music.mic")
            let sub = NSMenu()
            sub.minimumWidth = MenuLayout.width
            for kind in LyricsProviderKind.allCases {
                let mi = NSMenuItem(title: fixedMenuTitle(kind.display), action: #selector(menuSetProvider(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = kind.rawValue
                mi.state = (Settings.shared.provider == kind) ? .on : .off
                sub.addItem(mi)
            }
            providerItem.submenu = sub
            menu.addItem(providerItem)

            menu.addItem(.separator())
            menu.addItem(section("Library"))
            let count = LyricsStore.shared.trackCount()
            menu.addItem(item("Build lyrics library from Spotify…", #selector(menuBuildLibrary),
                              enabled: !LibraryBuilder.shared.isRunning,
                              symbol: "square.and.arrow.down"))
            menu.addItem(informationalItem("Library: \(count) song\(count == 1 ? "" : "s") cached",
                                           symbol: "externaldrive"))

            menu.addItem(.separator())
            menu.addItem(section("Account"))
            menu.addItem(informationalItem("Logged in to Spotify", symbol: "checkmark.circle"))
            menu.addItem(item("Log out", #selector(menuLogout), symbol: "rectangle.portrait.and.arrow.right"))
        } else {
            menu.addItem(section("Setup"))
            menu.addItem(item(hasClient ? "Set Spotify Client ID…" : "① Set Spotify Client ID…",
                              #selector(menuSetClientId),
                              symbol: "key"))
            let login = item("② Log in to Spotify…", #selector(menuLogin), symbol: "person.crop.circle")
            login.isEnabled = hasClient
            menu.addItem(login)
            menu.addItem(.separator())
            menu.addItem(item("How to get a Client ID…", #selector(menuHelp), symbol: "questionmark.circle"))
        }

        menu.addItem(.separator())
        menu.addItem(item("Quit lyrbar", #selector(menuQuit), symbol: "power"))
        return menu
    }

    private func section(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem()
        mi.view = MenuSectionHeaderView(title)
        return mi
    }

    private func item(_ title: String, _ action: Selector?, enabled: Bool = true, symbol: String? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: fixedMenuTitle(title), action: action, keyEquivalent: "")
        mi.target = self
        mi.isEnabled = enabled && action != nil
        if let symbol { mi.image = menuImage(symbol) }
        return mi
    }

    private func informationalItem(_ title: String, symbol: String? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: fixedMenuTitle(title), action: nil, keyEquivalent: "")
        mi.isEnabled = false
        if let symbol { mi.image = menuImage(symbol) }
        return mi
    }

    private func menuImage(_ symbol: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    private func fixedMenuTitle(_ title: String) -> String {
        let font = NSFont.menuFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard (title as NSString).size(withAttributes: attributes).width > MenuLayout.titleWidth else {
            return title
        }

        let ellipsis = "…"
        var low = 0
        var high = title.count
        var best = ellipsis
        while low <= high {
            let mid = (low + high) / 2
            let prefix = String(title.prefix(mid)) + ellipsis
            let width = (prefix as NSString).size(withAttributes: attributes).width
            if width <= MenuLayout.titleWidth {
                best = prefix
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let mi = NSMenuItem()
        mi.view = view
        return mi
    }

    // MARK: Menu actions

    @objc private func menuShowLyrics() { togglePopover() }
    @objc private func menuNextMatch() { engine.cycleCandidate() }
    @objc private func menuTrash() { engine.trashCurrent() }
    @objc private func menuReload() { engine.reload() }
    @objc private func menuResetOffset() { engine.setOffset(0) }
    @objc private func menuResetGlobalOffset() { engine.setGlobalOffset(0) }
    @objc private func menuResume() { engine.resume() }
    @objc private func menuToggleLongLineScroll() {
        Settings.shared.scrollLongLines.toggle()
        scheduleWidthRender()
    }

    @objc private func menuBuildLibrary() {
        guard !LibraryBuilder.shared.isRunning else { return }
        isImporting = true
        render("📥 Building lyrics library…")
        let kind = Settings.shared.provider
        Task {
            let result = await LibraryBuilder.shared.run(
                client: client, store: LyricsStore.shared, kind: kind
            ) { progress in
                Task { @MainActor in self.showImportProgress(progress) }
            }
            self.finishImport(result)   // back on the main actor here
        }
    }

    private func showImportProgress(_ p: LibraryProgress) {
        guard isImporting else { return }
        render(p.total > 0 ? "📥 \(p.done)/\(p.total) lyrics…" : "📥 \(p.phase)")
    }

    private func finishImport(_ r: LibraryBuilder.Result) {
        isImporting = false
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Lyrics library updated"
        var info = "Added \(r.added) new song\(r.added == 1 ? "" : "s") (scanned \(r.scanned)).\n"
        info += "Library now holds \(r.totalTracks) cached song\(r.totalTracks == 1 ? "" : "s")."
        if !r.sources.isEmpty { info += "\n\nFrom: \(r.sources)" }
        if let note = r.note { info += "\n\n⚠︎ \(note)" }
        alert.informativeText = info
        alert.runModal()
        render(statusText)   // engine updates resume normally now
    }

    @objc private func menuSetProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = LyricsProviderKind(rawValue: raw) else { return }
        Settings.shared.provider = kind
        engine.reload()
    }

    @objc private func menuSetClientId() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Spotify Client ID"
        alert.informativeText = "Paste the Client ID from your Spotify app at developer.spotify.com.\nThe app's Redirect URI must be exactly:\n\(Settings.shared.redirectURI)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = Settings.shared.clientId ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Settings.shared.clientId = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            refreshAccountState()
        }
    }

    @objc private func menuLogin() { beginLogin() }

    func beginLogin() {
        guard Settings.shared.clientId?.isEmpty == false else { menuSetClientId(); return }
        render("♪ lyrbar — opening browser…")
        Task {
            do {
                try await auth.login()
                refreshAccountState()
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Spotify login failed"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                refreshAccountState()
            }
        }
    }

    @objc private func menuLogout() {
        auth.cancelLogin()
        TokenStore.shared.clear()
        refreshAccountState()
    }

    @objc private func menuHelp() {
        NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Create a Spotify app"
        alert.informativeText = """
        1. Open developer.spotify.com/dashboard and click “Create app”.
        2. Set the Redirect URI to exactly:
           \(Settings.shared.redirectURI)
        3. Under APIs, tick “Web API”.
        4. Copy the Client ID, then use “Set Spotify Client ID…”.
        """
        alert.runModal()
    }

    @objc private func menuQuit() { NSApp.terminate(nil) }
}
