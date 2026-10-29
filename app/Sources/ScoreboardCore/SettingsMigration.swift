import Foundation

// 3.2.2 renamed the bundle id, which moves UserDefaults to a new domain.
public enum SettingsMigration {
    // Copies the old domain into the new one, once: only while the new domain
    // is still empty. `dropping` keys are left behind. Returns whether it ran.
    @discardableResult
    public static func copyDomain(
        from old: String, to new: String, dropping: [String] = [],
        in defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.persistentDomain(forName: new)?.isEmpty ?? true,
            var settings = defaults.persistentDomain(forName: old), !settings.isEmpty
        else { return false }
        for key in dropping { settings.removeValue(forKey: key) }
        defaults.setPersistentDomain(settings, forName: new)
        return true
    }
}
