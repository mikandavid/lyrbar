import AppKit

@MainActor
final class StatusController: NSObject, LyricsEngineDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let auth = SpotifyAuth()
    private lazy var client = SpotifyClient(auth: auth)
    private lazy var engine = LyricsEngine(client: client)

    private let popover = NSPopover()
    private lazy var popoverVC = LyricsPopoverController(engine: engine)

    private var statusText = "♪ lyrbar"
    private var clickMonitor: Any?
    private var isImporting = false

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
            self?.render(self?.statusText ?? "")
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
            if devices.isEmpty {
                let mi = NSMenuItem(title: "No devices available", action: nil, keyEquivalent: "")
                mi.isEnabled = false
                menu.addItem(mi)
                menu.addItem(.separator())
                let hint = NSMenuItem(title: "Open Spotify on a device to see it here",
                                      action: nil, keyEquivalent: "")
                hint.isEnabled = false
                menu.addItem(hint)
            } else {
                let header = NSMenuItem(title: "Play on…", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for d in devices {
                    let mi = NSMenuItem(title: d.name, action: #selector(self.devicePicked(_:)), keyEquivalent: "")
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

    // MARK: Rendering

    private func render(_ text: String) {
        statusText = text
        guard let button = statusItem.button else { return }
        let font = NSFont.systemFont(ofSize: 13)
        button.font = font
        // Left-align the lyric within the item and truncate to fit, so text
        // hugs the left edge and never draws past the item's bounds (which is
        // what made it appear to overlap the neighbouring menu bar item).
        button.alignment = .left
        button.imagePosition = .noImage
        // Fixed width set by the slider; only mutate when it actually changes
        // to avoid menu-bar layout thrash.
        let width = Settings.shared.width
        button.title = Self.truncate(text, toWidth: width - 14, font: font)
        if statusItem.length != width { statusItem.length = width }
    }

    private static func truncate(_ s: String, toWidth width: Double, font: NSFont) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (s as NSString).size(withAttributes: attrs).width <= width { return s }
        var lo = 0, hi = s.count
        let chars = Array(s)
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let candidate = String(chars.prefix(mid)) + "…"
            if (candidate as NSString).size(withAttributes: attrs).width <= width { lo = mid } else { hi = mid - 1 }
        }
        return String(chars.prefix(lo)) + "…"
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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
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
        let hasClient = Settings.shared.clientId?.isEmpty == false
        let loggedIn = auth.isLoggedIn

        if let np = engine.nowPlaying {
            let header = NSMenuItem(title: "\(np.title) — \(np.artist)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }

        if hasClient && loggedIn {
            if engine.isSuspended {
                menu.addItem(item("▶︎ Resume syncing", #selector(menuResume)))
                menu.addItem(.separator())
            }
            menu.addItem(item("Show full lyrics", #selector(menuShowLyrics)))
            menu.addItem(item("Try next match", #selector(menuNextMatch),
                              enabled: engine.candidates.count > 1))
            menu.addItem(item("Trash these lyrics (wrong match)", #selector(menuTrash),
                              enabled: engine.current != nil))
            menu.addItem(item("Reload lyrics", #selector(menuReload)))
            menu.addItem(.separator())

            // Offset slider (per current song)
            let offset = SliderItemView(title: "Lyric offset (this song)",
                                        range: Settings.offsetRange,
                                        value: Double(engine.currentOffsetMs),
                                        format: { String(format: "%+d ms", Int($0)) })
            offset.onChange = { [weak self] in self?.engine.setOffset(Int($0)) }
            offset.isEnabled = engine.nowPlaying != nil
            menu.addItem(viewItem(offset))
            menu.addItem(item("Reset offset", #selector(menuResetOffset),
                              enabled: engine.nowPlaying != nil))

            // Width slider
            let widthSlider = SliderItemView(title: "Menu bar width",
                                             range: Settings.widthRange,
                                             value: Settings.shared.width,
                                             format: { "\(Int($0)) px" })
            widthSlider.onChange = { [weak self] v in
                Settings.shared.width = v
                self?.render(self?.statusText ?? "")
            }
            menu.addItem(viewItem(widthSlider))

            // Provider submenu
            let providerItem = NSMenuItem(title: "Lyrics provider", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for kind in LyricsProviderKind.allCases {
                let mi = NSMenuItem(title: kind.display, action: #selector(menuSetProvider(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = kind.rawValue
                mi.state = (Settings.shared.provider == kind) ? .on : .off
                sub.addItem(mi)
            }
            providerItem.submenu = sub
            menu.addItem(providerItem)

            menu.addItem(.separator())
            let count = LyricsStore.shared.trackCount()
            menu.addItem(item("Build lyrics library from Spotify…", #selector(menuBuildLibrary),
                              enabled: !LibraryBuilder.shared.isRunning))
            menu.addItem(item("Library: \(count) song\(count == 1 ? "" : "s") cached", nil, enabled: false))

            menu.addItem(.separator())
            menu.addItem(item("Logged in to Spotify ✓", nil, enabled: false))
            menu.addItem(item("Log out", #selector(menuLogout)))
        } else {
            menu.addItem(item(hasClient ? "Set Spotify Client ID…" : "① Set Spotify Client ID…",
                              #selector(menuSetClientId)))
            let login = item("② Log in to Spotify…", #selector(menuLogin))
            login.isEnabled = hasClient
            menu.addItem(login)
            menu.addItem(.separator())
            menu.addItem(item("How to get a Client ID…", #selector(menuHelp)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Quit lyrbar", #selector(menuQuit)))
        return menu
    }

    private func item(_ title: String, _ action: Selector?, enabled: Bool = true) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.isEnabled = enabled && action != nil
        return mi
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
    @objc private func menuResume() { engine.resume() }

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
