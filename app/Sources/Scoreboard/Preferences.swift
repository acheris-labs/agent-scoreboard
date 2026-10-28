import Foundation

// UserDefaults-backed preferences, shared by the menu bar logic (which acts
// on them) and the Settings window (which edits them).
@MainActor
enum Preferences {
    private static let hideWhenIdleKey = "hideWhenIdle"
    private static let quitWhenEmptyKey = "quitWhenEmpty"
    static let idleHideDelayKey = "hideWhenIdleSeconds"
    static let emptyQuitDelayKey = "quitWhenEmptySeconds"
    static let defaultDelay = 60

    // Hide the icon once no lamp has been lit for a while.
    static var hideWhenIdle: Bool {
        get { UserDefaults.standard.bool(forKey: hideWhenIdleKey) }
        set { UserDefaults.standard.set(newValue, forKey: hideWhenIdleKey) }
    }

    // Quit once the board has been empty for a while.
    static var quitWhenEmpty: Bool {
        get { UserDefaults.standard.bool(forKey: quitWhenEmptyKey) }
        set { UserDefaults.standard.set(newValue, forKey: quitWhenEmptyKey) }
    }

    // 0 is a real value ("at once"), so absence has to be tested rather than
    // read as zero.
    static func delay(forKey key: String) -> Int {
        guard let stored = UserDefaults.standard.object(forKey: key) as? Int else {
            return defaultDelay
        }
        return min(max(stored, Delay.stops.first!), Delay.stops.last!)
    }

    static func setDelay(_ seconds: Int, forKey key: String) {
        UserDefaults.standard.set(seconds, forKey: key)
    }
}

enum Delay {
    /// Evenly spaced on the slider but logarithmically spaced in time: fine
    /// control over the short delays that matter, coarse over the long ones,
    /// and every stop is a round number rather than 37s or 143s.
    static let stops = [0, 1, 2, 5, 10, 15, 30, 45, 60, 90, 120, 180, 300, 600]

    /// Nearest stop to an arbitrary stored value, so a delay written by an
    /// older build (or by hand) still lands on the slider.
    static func index(forSeconds seconds: Int) -> Int {
        stops.enumerated()
            .min { abs($0.element - seconds) < abs($1.element - seconds) }?.offset ?? 0
    }

    static func label(_ seconds: Int) -> String {
        switch seconds {
        case 0: return "at once"
        case ..<60: return "\(seconds)s"
        case let s where s % 60 == 0: return "\(s / 60) min"
        default: return "\(seconds / 60)m \(seconds % 60)s"
        }
    }
}
