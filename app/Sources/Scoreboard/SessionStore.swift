import Foundation

enum SessionState: String, Codable {
    case running, idle, waiting, error, ended

    // Idle and ended sessions want no attention, so they light no lamp.
    var level: StatusLevel? {
        switch self {
        case .running: return .running
        case .waiting: return .waiting
        case .error: return .error
        case .idle, .ended: return nil
        }
    }
}

struct Session: Codable {
    let sessionId: String
    var state: SessionState
    var title: String
    var cwd: String
    var pid: Int32
    var updatedAt: Double  // epoch seconds, matches the CLI's snapshot reader
    var origin: [String: String]?  // opaque terminal identity, adapter-interpreted
    var titlePinned: Bool?  // user renamed; hook auto-titles must not clobber
}

// Owns all session state: applies socket events, persists an atomic snapshot
// the CLI's `scoreboard state` reads, and reaps sessions whose process died
// without a SessionEnd hook. Main-queue only - no locking.
@MainActor
final class SessionStore {
    private(set) var sessions: [String: Session] = [:]
    var onChange: (() -> Void)?

    func apply(event: [String: Any]) {
        guard let sessionId = event["session_id"] as? String, !sessionId.isEmpty else {
            NSLog("scoreboard: dropping malformed event")
            return
        }
        let eventOrigin = (event["origin"] as? [String: Any])?.compactMapValues { $0 as? String }
        let eventTitle = (event["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        guard let stateRaw = event["state"] as? String else {
            // Stateless event = metadata update (origin / rename); the
            // session must already exist.
            guard var session = sessions[sessionId] else { return }
            if let eventOrigin { session.origin = eventOrigin }
            if let eventTitle { session.title = eventTitle }
            if event["title_pinned"] as? Bool == true { session.titlePinned = true }
            sessions[sessionId] = session
            save()
            onChange?()
            return
        }
        guard let state = SessionState(rawValue: stateRaw) else {
            NSLog("scoreboard: dropping malformed event")
            return
        }
        if state == .ended {
            guard sessions.removeValue(forKey: sessionId) != nil else { return }
        } else {
            let previous = sessions[sessionId]
            let pinned = previous?.titlePinned == true
            sessions[sessionId] = Session(
                sessionId: sessionId,
                state: state,
                title: pinned
                    ? previous!.title
                    : eventTitle ?? previous?.title ?? "claude",
                cwd: event["cwd"] as? String ?? previous?.cwd ?? "",
                pid: Int32(event["pid"] as? Int ?? 0),
                updatedAt: event["ts"] as? Double ?? Date().timeIntervalSince1970,
                // Origin is captured only at SessionStart; carry it across
                // the hooks that fire without one.
                origin: eventOrigin ?? previous?.origin,
                titlePinned: previous?.titlePinned
            )
        }
        save()
        onChange?()
    }

    // kill(pid, 0) probes liveness: ESRCH means the process is gone. EPERM
    // still means alive. pid 0 (unknown) is exempt; SessionEnd clears those.
    func reapDead() {
        let dead = sessions.values.filter { session in
            session.pid > 0 && kill(session.pid, 0) != 0 && errno == ESRCH
        }
        guard !dead.isEmpty else { return }
        for session in dead { sessions.removeValue(forKey: session.sessionId) }
        save()
        onChange?()
    }

    func load() {
        guard let data = FileManager.default.contents(atPath: Paths.snapshot),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        sessions = Dictionary(
            snapshot.sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { _, b in b })
    }

    func save() {
        let snapshot = Snapshot(sessions: Array(sessions.values))
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let tmp = Paths.snapshot + ".tmp"
        do {
            try FileManager.default.createDirectory(
                atPath: Paths.stateDir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: tmp))
            try? FileManager.default.removeItem(atPath: Paths.snapshot)
            try FileManager.default.moveItem(atPath: tmp, toPath: Paths.snapshot)
        } catch {
            NSLog("scoreboard: snapshot write failed: \(error)")
        }
    }

    private struct Snapshot: Codable {
        var sessions: [Session]
    }
}
