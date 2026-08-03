import Foundation

// Map Claude Code hook payloads to scoreboard state events.
// Pure: no I/O beyond the injected origin capture, never throws on malformed
// input. States: running | idle | waiting | error | ended.
public enum Mapping {
    // Idle-prompt Notifications mean Claude is done, not blocked on us.
    // Current Claude Code versions send free-text `message` with no
    // `notification_type`, so fall back to matching known idle phrasings.
    static let idlePhrases = [
        "waiting for your input", "idle", "finished", "no longer",
    ]

    public static func isIdleNotification(_ payload: [String: Any]) -> Bool {
        guard payload["hook_event_name"] as? String == "Notification" else { return false }
        if let type = payload["notification_type"] as? String, !type.isEmpty {
            return type == "idle_prompt"
        }
        let message = (payload["message"] as? String ?? "").lowercased()
        return idlePhrases.contains { message.contains($0) }
    }

    /// Returns a scoreboard event for a hook payload, or nil to ignore it.
    public static func mapHook(
        _ payload: [String: Any],
        captureOrigin: () -> [String: String]? = { TerminalCapture.captureOrigin() },
        parentPID: Int32 = getppid()
    ) -> [String: Any]? {
        guard let sessionID = payload["session_id"] as? String, !sessionID.isEmpty else {
            return nil
        }
        let name = payload["hook_event_name"] as? String ?? ""
        let tool = payload["tool_name"] as? String

        let state: String
        let reason: String
        switch name {
        case "SessionStart":
            // A fresh session sits at the prompt: idle until the first submit.
            (state, reason) = ("idle", "session_start")
        case "UserPromptSubmit":
            (state, reason) = ("running", "prompt")
        case "Stop":
            (state, reason) = ("idle", "stop")
        case "Notification":
            (state, reason) = isIdleNotification(payload)
                ? ("idle", "idle") : ("waiting", "notification")
        case "PermissionRequest":
            (state, reason) = ("waiting", tool == "AskUserQuestion" ? "question" : "permission_request")
        case "PreToolUse":
            guard tool == "AskUserQuestion" else { return nil }
            (state, reason) = ("waiting", "question")
        case "PostToolUse":
            // Nothing fires when the user answers a question or grants a
            // permission, so a session would sit on "waiting" until the next
            // Stop. A finished tool call is proof work resumed.
            (state, reason) = ("running", tool == "AskUserQuestion" ? "question_answered" : "tool_done")
        case "StopFailure":
            (state, reason) = ("error", (payload["error_type"] as? String) ?? "stop_failure")
        case "SessionEnd":
            (state, reason) = ("ended", "session_end")
        default:
            return nil
        }

        let cwd = payload["cwd"] as? String ?? ""
        var event: [String: Any] = [
            "v": 1,
            "session_id": sessionID,
            "state": state,
            "reason": reason,
            "title": title(forCwd: cwd),
            "cwd": cwd,
            "pid": Int(parentPID),
            "ts": Date().timeIntervalSince1970,
        ]
        // Terminal origin is captured only at SessionStart: the user just
        // typed `claude` in that tab, so the focused terminal is the session's
        // home. Later hooks may fire while the user is elsewhere.
        if name == "SessionStart", let origin = captureOrigin() {
            event["origin"] = origin
        }
        return event
    }

    static func title(forCwd cwd: String) -> String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let base = (trimmed as NSString).lastPathComponent
        return base.isEmpty || base == "/" ? "claude" : base
    }
}
