import AppKit
import ScoreboardCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let store = SessionStore()
    private let login = LoginItemController()
    private var server: SocketServer?
    private var reapTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    // Rebuilding the menu while it is open yanks it shut; defer until close.
    private var menuIsTracking = false
    private var menuRebuildDeferred = false

    // With no sessions on the board, quit after this long. Generous so a
    // session that is starting up never races the timer.
    private var emptyTimer: Timer?
    private static let emptyQuitDelay: TimeInterval = 60
    private static let quitWhenEmptyKey = "quitWhenEmpty"

    private var quitWhenEmpty: Bool {
        UserDefaults.standard.bool(forKey: Self.quitWhenEmptyKey)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        terminateOlderInstances()

        store.load()
        store.reapDead()
        store.onChange = { [weak self] in self?.refresh() }

        let server = SocketServer { [weak self] event in
            self?.store.apply(event: event)
        }
        do {
            try server.start()
        } catch {
            NSLog("scoreboard: socket listen failed: \(error)")
        }
        self.server = server

        reapTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.reapDead() }
        }

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusItem()

        // macOS sometimes reaps status items on sleep and never restores them:
        // the process keeps running, the icon just vanishes. These sleep/wake
        // notifications post only on the *workspace* center, never the default
        // NotificationCenter.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreStatusItemIfNeeded() }
        }

        // First run defaults to Open at Login - afterward, respect the user.
        if let message = login.bootstrapDefaultIfNeeded() { NSLog("scoreboard: \(message)") }
        // Keep the marker honest even if the setting was changed elsewhere.
        writeAutostartMarker()
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // Shared by launch and rebuild so a recreated item behaves identically.
    private func configureStatusItem() {
        // Persist the icon's menu bar position. Without an autosave name a
        // fresh item lands at the left end of the status area - the side a
        // notch clips first - and any position the user drags to is forgotten
        // on the next launch. Never rename this: the saved position is keyed
        // off it.
        statusItem.autosaveName = "ScoreboardStatusItem"
        statusItem.menu = menu
    }

    // Re-assert the status item, preferring the cheap path. Recreating an
    // NSStatusItem churns its menu bar position - on a crowded bar that can
    // drop the icon into the strip a notch clips - so toggle isVisible first
    // and rebuild only if the item is genuinely gone. A live item's button is
    // hosted in an NSStatusBarWindow; once reaped it has no window.
    private func restoreStatusItemIfNeeded() {
        guard statusItem.button?.window == nil else { return }
        statusItem.isVisible = true
        // AppKit doesn't rehost the button synchronously, so give it a runloop
        // turn before concluding the item is unrecoverable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.statusItem.button?.window == nil else { return }
            // Hand the old item back first: replacing only our reference
            // leaves the dead item in the status bar as a ghost icon.
            NSStatusBar.system.removeStatusItem(self.statusItem)
            self.statusItem = NSStatusBar.system.statusItem(
                withLength: NSStatusItem.variableLength)
            self.configureStatusItem()
            self.refresh()
        }
    }

    // What people try when the icon has vanished: re-opening the app while
    // it is already running.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        statusItem.isVisible = true
        restoreStatusItemIfNeeded()
        return true
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        let alert = NSAlert()
        alert.messageText = "Scoreboard \(version)"
        alert.informativeText = "MIT © 2026 Chris Madden"
        alert.alertStyle = .informational
        // The board's own glyph, all lamps lit, rather than a generic icon.
        alert.icon = iconImage(
            counts: [.running: 1, .waiting: 1, .error: 1], badge: nil, height: 96,
            filledHousing: true)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "GitHub")
        // An accessory app has no windows to bring forward, so the modal
        // would otherwise open behind whatever you were looking at.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn,
            let url = URL(string: "https://github.com/acheris-labs/agent-scoreboard")
        {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleQuitWhenEmpty(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!quitWhenEmpty, forKey: Self.quitWhenEmptyKey)
        writeAutostartMarker()
        refresh()
    }

    // The marker is the CLI's permission to relaunch us. A file rather than a
    // `defaults read`: no subprocess on the hook path, and no risk of reading
    // a value cfprefsd has not flushed yet.
    private func writeAutostartMarker() {
        do {
            if quitWhenEmpty {
                try FileManager.default.createDirectory(
                    atPath: Paths.stateDir, withIntermediateDirectories: true)
                try Data().write(to: URL(fileURLWithPath: Paths.autostart))
            } else if FileManager.default.fileExists(atPath: Paths.autostart) {
                try FileManager.default.removeItem(atPath: Paths.autostart)
            }
        } catch {
            NSLog("scoreboard: autostart marker: \(error)")
        }
    }

    // Arm a one-shot quit whenever the board is empty; any session cancels it.
    private func updateEmptyTimer() {
        emptyTimer?.invalidate()
        emptyTimer = nil
        // Never quit out from under an open menu - that is where the setting
        // gets switched off. menuDidClose re-arms.
        guard quitWhenEmpty, store.sessions.isEmpty, !menuIsTracking else { return }
        emptyTimer = Timer.scheduledTimer(
            withTimeInterval: Self.emptyQuitDelay, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.quitWhenEmpty, self.store.sessions.isEmpty,
                    !self.menuIsTracking
                else { return }
                NSLog("scoreboard: no sessions for \(Self.emptyQuitDelay)s, quitting")
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        if let message = login.setEnabled(!login.isEnabled) { NSLog("scoreboard: \(message)") }
        refresh()
    }

    // A second launch (make run while running) must own the socket: kill the
    // older instance first so unlinking its socket file is safe.
    private func terminateOlderInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.forceTerminate()
        }
    }

    // MARK: - Rendering

    private func refresh() {
        var counts: [StatusLevel: Int] = [:]
        for session in store.sessions.values {
            guard let level = session.state.level else { continue }
            counts[level, default: 0] += 1
        }
        statusItem.button?.image = statusItemImage(counts: counts)
        updateEmptyTimer()

        if menuIsTracking {
            menuRebuildDeferred = true
        } else {
            rebuildMenu()
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let sessions = store.sessions.values.sorted { a, b in
            let aUrgent = a.state == .waiting || a.state == .error
            let bUrgent = b.state == .waiting || b.state == .error
            if aUrgent != bUrgent { return aUrgent }
            return a.updatedAt > b.updatedAt
        }
        if sessions.isEmpty {
            let item = NSMenuItem(title: "No Claude sessions", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for session in sessions {
            // The dot is the item image and the title stays plain text:
            // attributed titles lose menu vibrancy and render dim, images
            // keep their own color while the text gets standard styling.
            let item = NSMenuItem(
                title: session.title, action: #selector(jump(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session.sessionId
            item.image = dotImage(for: session.state)
            item.isEnabled = true
            item.toolTip = "\(session.cwd)\n\(session.sessionId)"
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let quitWhenEmptyItem = NSMenuItem(
            title: "Quit When No Sessions", action: #selector(toggleQuitWhenEmpty(_:)),
            keyEquivalent: "")
        quitWhenEmptyItem.target = self
        quitWhenEmptyItem.state = quitWhenEmpty ? .on : .off
        quitWhenEmptyItem.toolTip =
            "Quit Scoreboard after a minute with no Claude sessions. "
            + "It starts itself again when the next session registers."
        menu.addItem(quitWhenEmptyItem)

        let loginItem = NSMenuItem(
            title: "Start at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = login.isEnabled ? .on : .off
        menu.addItem(loginItem)

        let aboutItem = NSMenuItem(
            title: "About Scoreboard", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(
            NSMenuItem(
                title: "Quit Scoreboard", action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))
    }

    @objc private func jump(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String,
            let session = store.sessions[sessionId]
        else { return }
        TerminalAdapters.jump(origin: session.origin, cwd: session.cwd)
    }

    private func dotImage(for state: SessionState) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        return NSImage(size: size, flipped: false) { _ in
            let rect = NSRect(x: 1.5, y: 1.5, width: 9, height: 9)
            if let level = state.level {
                level.color.setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuIsTracking = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsTracking = false
        // Quitting was suppressed while the menu was open; re-arm now.
        updateEmptyTimer()
        if menuRebuildDeferred {
            menuRebuildDeferred = false
            // Rebuild after tracking fully unwinds.
            DispatchQueue.main.async { [weak self] in self?.rebuildMenu() }
        }
    }
}
