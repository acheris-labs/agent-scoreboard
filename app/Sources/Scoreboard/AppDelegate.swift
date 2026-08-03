import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let store = SessionStore()
    private var server: SocketServer?
    private var reapTimer: Timer?

    // Rebuilding the menu while it is open yanks it shut; defer until close.
    private var menuIsTracking = false
    private var menuRebuildDeferred = false

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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = menu
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
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
        let states = Set(store.sessions.values.map(\.state))
        statusItem.button?.image = statusItemImage(
            hasError: states.contains(.error),
            hasWaiting: states.contains(.waiting),
            hasRunning: states.contains(.running))
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
            switch state {
            case .running:
                runningGreen.setFill()
                NSBezierPath(ovalIn: rect).fill()
            case .waiting:
                StatusDot.waiting.color.setFill()
                NSBezierPath(ovalIn: rect).fill()
            case .error:
                StatusDot.error.color.setFill()
                NSBezierPath(ovalIn: rect).fill()
            case .idle, .ended:
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
        if menuRebuildDeferred {
            menuRebuildDeferred = false
            // Rebuild after tracking fully unwinds.
            DispatchQueue.main.async { [weak self] in self?.rebuildMenu() }
        }
    }
}
