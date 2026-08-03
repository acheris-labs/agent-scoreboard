import AppKit

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

    // Hiding the icon would otherwise hide the only way to stop hiding it.
    // Re-opening the app forces it back until the menu is next dismissed.
    private var forceVisible = false
    private static let hideWhenEmptyKey = "hideWhenEmpty"

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
        // Also the escape hatch from "Hide When No Sessions": `open -a
        // Scoreboard` brings the icon back so the setting can be switched off.
        forceVisible = true
        statusItem.isVisible = true
        restoreStatusItemIfNeeded()
        return true
    }

    @objc private func toggleHideWhenEmpty(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: Self.hideWhenEmptyKey), forKey: Self.hideWhenEmptyKey)
        refresh()
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
        statusItem.button?.image = statusItemImage(mode: IconMode.current, counts: counts)

        let hideWhenEmpty = UserDefaults.standard.bool(forKey: Self.hideWhenEmptyKey)
        statusItem.isVisible = forceVisible || !(hideWhenEmpty && store.sessions.isEmpty)

        if menuIsTracking {
            menuRebuildDeferred = true
        } else {
            rebuildMenu()
        }
    }

    @objc private func setIconMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        UserDefaults.standard.set(mode, forKey: IconMode.defaultsKey)
        refresh()
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

        let iconItem = NSMenuItem(title: "Icon", action: nil, keyEquivalent: "")
        let iconMenu = NSMenu()
        for mode in IconMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName, action: #selector(setIconMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == IconMode.current ? .on : .off
            iconMenu.addItem(item)
        }
        iconItem.submenu = iconMenu
        menu.addItem(iconItem)

        let hideItem = NSMenuItem(
            title: "Hide When No Sessions", action: #selector(toggleHideWhenEmpty(_:)),
            keyEquivalent: "")
        hideItem.target = self
        hideItem.state =
            UserDefaults.standard.bool(forKey: Self.hideWhenEmptyKey) ? .on : .off
        hideItem.toolTip =
            "Remove the icon from the menu bar when no Claude sessions exist. "
            + "Open Scoreboard again to bring it back."
        menu.addItem(hideItem)

        let loginItem = NSMenuItem(
            title: "Start at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = login.isEnabled ? .on : .off
        menu.addItem(loginItem)

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
        // The forced reveal lasts only until the user has had their look.
        if forceVisible {
            forceVisible = false
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
        if menuRebuildDeferred {
            menuRebuildDeferred = false
            // Rebuild after tracking fully unwinds.
            DispatchQueue.main.async { [weak self] in self?.rebuildMenu() }
        }
    }
}
