import Foundation
import ScoreboardCore

// Unix-socket listener for hook events. Clients (the `scoreboard hook` CLI)
// connect, write one NDJSON line, and close - there is no reply protocol.
// Plain BSD sockets + DispatchSource on the main queue: predictable, ~no
// state, and every callback lands where SessionStore lives.
@MainActor
final class SocketServer {
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private let onEvent: ([String: Any]) -> Void

    private final class Connection {
        var buffer = Data()
        var readSource: DispatchSourceRead?
        var timeout: DispatchSourceTimer?
    }

    init(onEvent: @escaping ([String: Any]) -> Void) {
        self.onEvent = onEvent
    }

    func start() throws {
        try FileManager.default.createDirectory(
            atPath: Paths.stateDir, withIntermediateDirectories: true)
        // Stale socket from a previous instance: older instances of our
        // bundle id were terminated at launch, so it is safely ours.
        unlink(Paths.socket)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw Errno("socket") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard Paths.socket.utf8.count <= maxLen else { throw Errno("socket path too long") }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dest in
                strlcpy(dest, Paths.socket, maxLen + 1)
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listenFD, 16) == 0 else {
            close(listenFD)
            throw Errno("bind/listen")
        }
        chmod(Paths.socket, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        for fd in connections.keys { closeConnection(fd) }
        if listenFD >= 0 { close(listenFD) }
        unlink(Paths.socket)
    }

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        let connection = Connection()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.readClient(fd) }
        source.resume()
        connection.readSource = source

        // A client that connects and hangs must not leak an fd forever.
        let timeout = DispatchSource.makeTimerSource(queue: .main)
        timeout.schedule(deadline: .now() + 2.0)
        timeout.setEventHandler { [weak self] in self?.finishConnection(fd) }
        timeout.resume()
        connection.timeout = timeout

        connections[fd] = connection
    }

    private func readClient(_ fd: Int32) {
        guard let connection = connections[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &chunk, chunk.count)
        if count > 0 {
            connection.buffer.append(contentsOf: chunk[0..<count])
            if connection.buffer.count > 65536 || connection.buffer.contains(0x0A) {
                finishConnection(fd)
            }
        } else if count == 0 {
            finishConnection(fd)  // EOF
        } else if errno != EAGAIN && errno != EINTR {
            closeConnection(fd)
        }
    }

    private func finishConnection(_ fd: Int32) {
        guard let connection = connections[fd] else { return }
        let line = connection.buffer.prefix(while: { $0 != 0x0A })
        closeConnection(fd)
        guard !line.isEmpty else { return }
        guard
            let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else {
            NSLog("scoreboard: dropping unparseable event line")
            return
        }
        onEvent(event)
    }

    private func closeConnection(_ fd: Int32) {
        guard let connection = connections.removeValue(forKey: fd) else { return }
        connection.readSource?.cancel()
        connection.timeout?.cancel()
        close(fd)
    }

    private struct Errno: Error, CustomStringConvertible {
        let stage: String
        let code: Int32
        init(_ stage: String) {
            self.stage = stage
            self.code = errno
        }
        var description: String { "\(stage): \(String(cString: strerror(code)))" }
    }
}
