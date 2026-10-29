import AppKit
import ScoreboardCore
import SwiftUI

// The Settings window: which Claude config folders carry our hooks, plus the
// app's own preferences. The model writes through to UserDefaults and the
// config folder list, then tells the app delegate to re-apply them.
@MainActor
final class SettingsModel: ObservableObject {
    enum Status {
        case registered, incomplete, missing, unreadable

        var label: String {
            switch self {
            case .registered: return "hooks ✓"
            case .incomplete: return "some hooks missing"
            case .missing: return "no hooks"
            case .unreadable: return "settings.json unreadable"
            }
        }
    }

    struct Folder: Identifiable {
        let path: String
        let status: Status
        var id: String { path }
        var display: String { (path as NSString).abbreviatingWithTildeInPath }
    }

    @Published private(set) var folders: [Folder] = []
    @Published var hideWhenIdle = Preferences.hideWhenIdle {
        didSet { Preferences.hideWhenIdle = hideWhenIdle; onChange() }
    }
    @Published var hideDelay = Preferences.delay(forKey: Preferences.idleHideDelayKey) {
        didSet { Preferences.setDelay(hideDelay, forKey: Preferences.idleHideDelayKey); onChange() }
    }
    @Published var quitWhenEmpty = Preferences.quitWhenEmpty {
        didSet { Preferences.quitWhenEmpty = quitWhenEmpty; onChange() }
    }
    @Published var quitDelay = Preferences.delay(forKey: Preferences.emptyQuitDelayKey) {
        didSet { Preferences.setDelay(quitDelay, forKey: Preferences.emptyQuitDelayKey); onChange() }
    }
    @Published var startAtLogin: Bool

    private let login: LoginItemController
    private let configFolders = ConfigFolders.standard
    private let onChange: () -> Void

    init(login: LoginItemController, onChange: @escaping () -> Void) {
        self.login = login
        self.onChange = onChange
        self.startAtLogin = login.isEnabled
    }

    // The window binds to this rather than to `startAtLogin` directly: the
    // switch must show what macOS actually did, which may not be what was
    // asked for.
    func setStartAtLogin(_ on: Bool) {
        if let message = login.setEnabled(on) { NSLog("scoreboard: \(message)") }
        startAtLogin = login.isEnabled
    }

    func reload() {
        folders = configFolders.list().map { path in
            Folder(path: path, status: Self.status(of: path))
        }
        startAtLogin = login.isEnabled
    }

    private static func status(of folder: String) -> Status {
        guard let scan = try? Settings.scan(ConfigFolders.settingsPath(folder)) else {
            return .unreadable
        }
        if scan.values.allSatisfy({ $0 }) { return .registered }
        return scan.values.contains(true) ? .incomplete : .missing
    }

    func addFolder(attachedTo window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // Config folders are dot-folders in your home: ~/.claude, ~/.claude-work.
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.message = "Choose a Claude config folder: ~/.claude, or one you set as CLAUDE_CONFIG_DIR."
        panel.prompt = "Add"
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.configFolders.add(url.path)
            } catch {
                Self.showError("Couldn't add \(url.path)", error)
            }
            self.reload()
            self.onChange()
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    func removeFolder(_ path: String) {
        do {
            try configFolders.remove(path)
        } catch {
            Self.showError("Couldn't remove hooks from \(path)", error)
        }
        reload()
        onChange()
    }

    private static func showError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.runModal()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let window: () -> NSWindow?
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude config folders").font(.headline)
            List(model.folders, selection: $selection) { folder in
                HStack {
                    Text(folder.display)
                    Spacer()
                    Text(folder.status.label)
                        .foregroundColor(folder.status == .registered ? .secondary : .orange)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 120)
            .overlay {
                if model.folders.isEmpty {
                    Text("No folders yet. Click + and choose ~/.claude to get started.")
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 4) {
                Button {
                    model.addFolder(attachedTo: window())
                } label: {
                    Image(systemName: "plus").frame(width: 16, height: 16)
                }
                .help("Add a Claude config folder")
                Button {
                    if let selection { model.removeFolder(selection) }
                    selection = nil
                } label: {
                    Image(systemName: "minus").frame(width: 16, height: 16)
                }
                .disabled(selection == nil)
                .help("Remove the hooks from the selected folder")
            }
            Text("Scoreboard adds its hooks to settings.json in each folder. Add one for every CLAUDE_CONFIG_DIR you run Claude with.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 6)

            Toggle("Hide when idle", isOn: $model.hideWhenIdle)
                .help("Remove the icon once no session is running, waiting or in error. Run `open -a Scoreboard` to bring it back.")
            DelaySlider(title: "Hide after", seconds: $model.hideDelay)
                .disabled(!model.hideWhenIdle)
            Toggle("Quit when no sessions", isOn: $model.quitWhenEmpty)
                .help("Quit once there are no Claude sessions at all. It starts again when the next session registers.")
            DelaySlider(title: "Quit after", seconds: $model.quitDelay)
                .disabled(!model.quitWhenEmpty)
            Toggle(
                "Start at login",
                isOn: Binding(get: { model.startAtLogin }, set: { model.setStartAtLogin($0) }))
            if model.folders.isEmpty {
                Text("Hiding and quitting are paused until a config folder is added: until then the menu bar icon is the only way back here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct DelaySlider: View {
    let title: String
    @Binding var seconds: Int

    var body: some View {
        let index = Binding<Double>(
            get: { Double(Delay.index(forSeconds: seconds)) },
            set: { seconds = Delay.stops[min(max(Int($0.rounded()), 0), Delay.stops.count - 1)] })
        HStack {
            Text(title).foregroundColor(.secondary)
            Slider(value: index, in: 0...Double(Delay.stops.count - 1), step: 1)
            Text(Delay.label(seconds))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.leading, 20)
    }
}

@MainActor
final class SettingsWindowController {
    let model: SettingsModel
    private var window: NSWindow?

    init(model: SettingsModel) {
        self.model = model
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        model.reload()
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(model: model, window: { [weak self] in self?.window }))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Scoreboard Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // An accessory app has no Dock icon to come forward with, so the
        // window would otherwise open behind whatever you were looking at.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
