import Foundation
import ServiceManagement

// Whether Scoreboard launches at login, via the modern SMAppService.mainApp
// API (no LaunchAgent plist to install or clean up).
@MainActor
final class LoginItemController {
    private var service: SMAppService { SMAppService.mainApp }
    private let bootstrappedKey = "LoginItemBootstrapped"

    var isEnabled: Bool { service.status == .enabled }

    // On the very first launch, default Open at Login to on. Recorded so we
    // never auto-toggle again - a later choice to turn it off is honored.
    @discardableResult
    func bootstrapDefaultIfNeeded() -> String? {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: bootstrappedKey) else { return nil }
        defaults.set(true, forKey: bootstrappedKey)
        return setEnabled(true)
    }

    // Returns a user-facing message on failure, nil on success.
    @discardableResult
    func setEnabled(_ on: Bool) -> String? {
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
            return nil
        } catch {
            return "Open at login: \(error.localizedDescription)"
        }
    }
}
