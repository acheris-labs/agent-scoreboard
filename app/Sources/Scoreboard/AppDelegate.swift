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
    private var sleepObserver: NSObjectProtocol?
    private var pruneTimer: Timer?
    private let details = DetailsWindowController()

    // Rebuilding the menu while it is open yanks it shut; defer until close.
    private var menuIsTracking = false
    private var menuRebuildDeferred = false

    // With no sessions on the board, quit after this long. Generous so a
    // session that is starting up never races the timer.
    private var emptyTimer: Timer?

    // Hide the icon once no lamp has been lit for a while. Separate from
    // quitWhenEmpty: that one is about an empty board, this one is about a
    // board where nothing wants you.
    private var idleTimer: Timer?

    private lazy var settings = SettingsWindowController(
        model: SettingsModel(login: login) { [weak self] in
            self?.writeAutostartMarker()
            self?.refresh()
        })

    // A hidden icon hides the menu that turns hiding off. Re-opening the app
    // forces it back until the menu is next dismissed.
    private var forceVisible = false

    // With no config folder registered no session can ever reach the board,
    // and nothing would ever relaunch us: hiding or quitting would strand the
    // app with no way back to Settings. Both wait until a folder is added.
    private var hasConfigFolders: Bool { !ConfigFolders.standard.list().isEmpty }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        terminateOlderInstances()

        // Close whatever a crash left open before anything new is logged.
        store.history.recover()
        store.load()
        store.reapDead()
        store.reopenHistory()
        store.onChange = { [weak self] in self?.refresh() }
        pruneHistory()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneHistory() }
        }

        let server = SocketServer { [weak self] event in
            self?.store.apply(event: event)
        }
        do {
            try server.start()
        } catch {
            NSLog("scoreboard: socket listen failed: \(error)")
        }
        self.server = server

        store.history.log.touchAlive()
        reapTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.reapDead()
                // The last sign of life, should we die without a clean quit.
                self?.store.history.log.touchAlive()
            }
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
            MainActor.assumeIsolated {
                guard let self else { return }
                self.restoreStatusItemIfNeeded()
                // Sessions that died while we slept end now, not at wake.
                self.store.reapDead()
                self.store.reopenHistory()
            }
        }
        // Time asleep isn't time spent waiting on anyone.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.closeHistory() }
        }

        // First run defaults to Open at Login - afterward, respect the user.
        if let message = login.bootstrapDefaultIfNeeded() { NSLog("scoreboard: \(message)") }
        // Keep the marker honest even if the setting was changed elsewhere.
        writeAutostartMarker()
        installMainMenu()
        // Closing Settings is when a suppressed quit-when-empty may re-arm.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.async { self?.refresh() }
            }
        }
        refresh()

        // Nothing is registered on install: until a config folder is added,
        // no session can ever reach the board, so open Settings to say so.
        let folders = ConfigFolders.standard
        folders.migrateIfNeeded()
        if folders.list().isEmpty { settings.show() }
    }

    // An accessory app shows no menu bar, but its main menu still handles
    // key equivalents while one of its windows is key: this is what makes
    // Cmd-W close Settings.
    private func installMainMenu() {
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            NSMenuItem(
                title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func showSettings(_ sender: Any?) {
        settings.show()
    }

    @objc private func showDetails(_ sender: Any?) {
        details.show()
    }

    private func pruneHistory() {
        store.history.log.prune(
            olderThan: Date().timeIntervalSince1970 - HistoryRange.retention)
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        store.closeHistory()
        for observer in [wakeObserver, sleepObserver].compactMap({ $0 }) {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
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
        // Also the way back from Hide When Idle: `open -a Scoreboard` brings
        // the icon out of hiding long enough to use the menu.
        forceVisible = true
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

    // The marker is the CLI's permission to relaunch us. A file rather than a
    // `defaults read`: no subprocess on the hook path, and no risk of reading
    // a value cfprefsd has not flushed yet.
    private func writeAutostartMarker() {
        do {
            if Preferences.quitWhenEmpty {
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

    // A lit lamp shows the icon at once - if something wants you, it must be
    // there immediately. Going quiet only starts a timer, so the icon does not
    // flicker away between a session finishing and the next prompt.
    private func updateIdleVisibility(anyLit: Bool) {
        idleTimer?.invalidate()
        idleTimer = nil
        guard Preferences.hideWhenIdle, !forceVisible, hasConfigFolders else {
            statusItem.isVisible = true
            return
        }
        if anyLit {
            statusItem.isVisible = true
            return
        }
        idleTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(Preferences.delay(forKey: Preferences.idleHideDelayKey)),
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Preferences.hideWhenIdle, !self.forceVisible,
                    !self.menuIsTracking, self.hasConfigFolders
                else { return }
                self.statusItem.isVisible = false
            }
        }
    }

    // Arm a one-shot quit whenever the board is empty; any session cancels it.
    private func updateEmptyTimer() {
        emptyTimer?.invalidate()
        emptyTimer = nil
        // Never quit out from under an open menu or window - Settings is where
        // the setting gets switched off. Closing any of them re-arms.
        guard Preferences.quitWhenEmpty, store.sessions.isEmpty, !menuIsTracking,
            !settings.isVisible, !details.isVisible, hasConfigFolders
        else { return }
        emptyTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(Preferences.delay(forKey: Preferences.emptyQuitDelayKey)),
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Preferences.quitWhenEmpty, self.store.sessions.isEmpty,
                    !self.menuIsTracking, !self.settings.isVisible, !self.details.isVisible,
                    self.hasConfigFolders
                else { return }
                NSLog("scoreboard: board empty, quitting")
                NSApp.terminate(nil)
            }
        }
    }

    // A second launch (make run while running) must own the socket: kill the
    // older instance first so unlinking its socket file is safe. That includes
    // a copy still running under the pre-3.2.2 bundle id.
    private func terminateOlderInstances() {
        for bundleID in Set([Paths.bundleID, Paths.legacyBundleID]) {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            where app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                app.forceTerminate()
            }
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
        updateIdleVisibility(anyLit: !counts.isEmpty)
        details.setNeedsReload()

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

        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let detailsItem = NSMenuItem(
            title: "Show Details", action: #selector(showDetails(_:)), keyEquivalent: "")
        detailsItem.target = self
        menu.addItem(detailsItem)

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
        TerminalAdapters.jump(origin: session.origin, pid: session.pid, cwd: session.cwd)
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
        // The forced reveal lasts only until the user has had their look.
        forceVisible = false
        // Quitting and hiding were suppressed while the menu was open.
        updateEmptyTimer()
        refresh()
        if menuRebuildDeferred {
            menuRebuildDeferred = false
            // Rebuild after tracking fully unwinds.
            DispatchQueue.main.async { [weak self] in self?.rebuildMenu() }
        }
    }
}
