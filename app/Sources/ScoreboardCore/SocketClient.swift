import Foundation

// Deliver events to the app over its unix socket.
//
// Fire-and-forget: one NDJSON line per connection, hard timeout, never throws
// past the caller. When the app is down and "Quit When No Sessions" is on, it
// gets launched and the send retried.
public enum SocketClient {
    public static let sendTimeout = 0.25
    // How long to wait for a relaunched app to start listening. Bounded so a
    // hook never stalls Claude for long.
    public static let launchBudget = 3.0
    public static let launchPoll = 0.1

    public static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(
            atPath: Paths.stateDir, withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: Paths.log) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: Paths.log))
        }
    }

    /// One connect-write-close. Returns false if the app isn't listening.
    static func deliver(_ event: [String: Any]) -> Bool {
        guard let json = try? JSONSerialization.data(withJSONObject: event) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var timeout = timeval(
            tv_sec: Int(sendTimeout), tv_usec: Int32((sendTimeout - floor(sendTimeout)) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard Paths.socket.utf8.count <= maxLen else { return false }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dest in
                strlcpy(dest, Paths.socket, maxLen + 1)
            }
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }

        var payload = json
        payload.append(0x0A)
        return payload.withUnsafeBytes { buffer -> Bool in
            var sent = 0
            while sent < buffer.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// The app writes the marker only while Quit When No Sessions is on.
    /// Without it an explicit Quit must stick. Ending sessions never justify a
    /// launch: the app would boot only to record a row going away, then quit.
    static func mayLaunch(_ event: [String: Any]) -> Bool {
        if event["state"] as? String == "ended" { return false }
        return FileManager.default.fileExists(atPath: Paths.autostart)
    }

    // -g keeps it in the background so it never steals focus; by bundle id so
    // a Homebrew, ~/Applications, or dev build all resolve.
    static func launchApp() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-b", Paths.bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            log("launch failed: \(error)")
            return false
        }
    }

    @discardableResult
    public static func send(_ event: [String: Any]) -> Bool {
        let reason = event["reason"] as? String ?? "update"
        let session = event["session_id"] as? String ?? "?"
        let label = "\(reason) for \(session)"

        if !deliver(event) {
            guard mayLaunch(event) else {
                log("drop \(label): app not listening")
                return false
            }
            guard launchApp() else { return false }
            log("launching app to deliver \(label)")
            let deadline = Date().addingTimeInterval(launchBudget)
            var delivered = false
            while Date() < deadline {
                Thread.sleep(forTimeInterval: launchPoll)
                if deliver(event) {
                    delivered = true
                    break
                }
            }
            guard delivered else {
                log("drop \(label): app did not start within \(launchBudget)s")
                return false
            }
        }
        log("sent \(reason) (\(event["state"] as? String ?? "meta")) for \(session)")
        return true
    }
}
