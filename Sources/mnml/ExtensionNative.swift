import Foundation
import WebKit

// Chrome's native messaging, for the extensions that talk to an app on this
// Mac — a password manager unlocking with its desktop app, a clipper handing
// a page to a notes app.
//
// Those apps register with Chrome by leaving a small JSON file in Chrome's
// NativeMessagingHosts folder: a name, the program to run, and which
// extensions may run it. mnml reads the same files, runs the same program
// with the same argument, and speaks the same protocol — each message a
// four-byte length and a line of JSON, over the program's stdin and stdout.
// A host that lists the extension's id among its allowed origins is run;
// any other is not. Some hosts also check which browser is calling and may
// refuse one they don't know; that is theirs to decide.

@available(macOS 15.4, *)
enum ExtensionNative {
    struct Refused: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    /// Where Chromium browsers look, per user and for the whole Mac.
    private static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support")
        return [
            support.appendingPathComponent("Google/Chrome/NativeMessagingHosts"),
            support.appendingPathComponent("Chromium/NativeMessagingHosts"),
            support.appendingPathComponent("Microsoft Edge/NativeMessagingHosts"),
            support.appendingPathComponent("BraveSoftware/Brave-Browser/NativeMessagingHosts"),
            support.appendingPathComponent("Arc/User Data/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Application Support/Chromium/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Microsoft/Edge/NativeMessagingHosts"),
            // Read last: a host of the same name that Chrome or the system knows comes first.
            support.appendingPathComponent("Vivaldi/NativeMessagingHosts"),
            support.appendingPathComponent("com.operasoftware.Opera/NativeMessagingHosts"),
        ]
    }

    /// The program for `name`, if one is registered and lets this extension in.
    private static func host(_ name: String, for extensionID: String) throws -> URL {
        guard name.range(of: #"^[a-z0-9_]+(\.[a-z0-9_]+)*$"#, options: .regularExpression) != nil else {
            throw Refused(why: "Invalid native messaging host name")
        }
        let origin = "chrome-extension://\(extensionID)/"
        for folder in folders {
            let file = folder.appendingPathComponent(name + ".json")
            guard let data = try? Data(contentsOf: file),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = manifest["path"] as? String
            else { continue }
            let allowed = manifest["allowed_origins"] as? [String] ?? []
            guard allowed.contains(origin) else {
                throw Refused(why: "Access to the specified native messaging host is forbidden.")
            }
            let program = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
            guard FileManager.default.isExecutableFile(atPath: program.path) else {
                throw Refused(why: "Specified native messaging host not found.")
            }
            return program
        }
        throw Refused(why: "Specified native messaging host not found.")
    }

    /// `runtime.sendNativeMessage`: run, send one, read one, stop.
    static func send(_ message: Any, to name: String, from extensionID: String) async throws -> Any? {
        let program = try host(name, for: extensionID)
        let pipe = HostPipe(program: program, origin: "chrome-extension://\(extensionID)/")
        try pipe.start()
        defer { pipe.stop() }
        return try await pipe.request(message)
    }

    /// `runtime.connectNative`: run, and keep the two talking until either
    /// end lets go.
    @MainActor
    static func connect(_ port: WKWebExtension.MessagePort, from extensionID: String) throws {
        guard let name = port.applicationIdentifier else { throw Refused(why: "No host named") }
        let program = try host(name, for: extensionID)
        // A new port is often a worker starting over; the one before may
        // have left its host behind.
        stopOrphans()
        let pipe = HostPipe(program: program, origin: "chrome-extension://\(extensionID)/")
        var beating: Timer?
        pipe.onMessage = { [weak port] message in
            DispatchQueue.main.async { if let port, !port.isDisconnected { port.sendMessage(message, completionHandler: nil) } }
        }
        pipe.onExit = { [weak port] in
            DispatchQueue.main.async {
                beating?.invalidate()
                beating = nil
                guard let port else { return }
                port.messageHandler = nil
                port.disconnectHandler = nil
                if !port.isDisconnected { port.disconnect() }
            }
        }
        port.messageHandler = { [weak pipe, weak port] message, _ in
            guard let message, let pipe, let port, !port.isDisconnected else { return }
            // A worker's shim asking whether the port has arrived (see the
            // shim, after its WebSocket): answered here, never passed on.
            if let asked = message as? [String: Any], let word = asked["__searchNative"] {
                // The shim's answer to "alive" (below) is only the worker
                // keeping itself: nothing to say back.
                guard (word as? String) == "here?" else { return }
                port.sendMessage(["__searchNative": "here"], completionHandler: nil)
                // Asked, it is a worker's port, and WebKit unloads a worker
                // that hasn't posted on a port for two minutes: iCloud
                // Passwords then forgets it was paired and asks for a code
                // again. Chrome keeps a worker with a port to an app alive;
                // here a word on the port now and then, heard only by the
                // shim, has the worker answer on it, which is what WebKit
                // counts.
                if beating == nil {
                    beating = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak port] timer in
                        guard let port, !port.isDisconnected else { timer.invalidate(); return }
                        port.sendMessage(["__searchNative": "alive"], completionHandler: nil)
                    }
                }
                return
            }
            try? pipe.write(message)
        }
        port.disconnectHandler = { [weak pipe] _ in pipe?.stop() }
        Live.keep(pipe, for: port)
        do { try pipe.start() } catch { pipe.stop(); throw error }
    }

    /// WebKit doesn't always say when a port goes: an extension unloaded —
    /// taken up afresh, turned off, removed — leaves its worker's ports
    /// disconnected without calling their disconnect handlers. Each host
    /// would run on, with any code prompt it had open, until the browser
    /// quit: iCloud Passwords left a helper behind at every restart. So the
    /// hosts of ports that have gone are stopped here; a port still
    /// connected keeps its own.
    @MainActor
    static func stopOrphans() {
        for (pipe, port) in Live.pipes.values where port.isDisconnected { pipe.stop() }
    }

    /// Hosts that are connected, held until they end.
    private enum Live {
        nonisolated(unsafe) static var pipes: [ObjectIdentifier: (pipe: HostPipe, port: WKWebExtension.MessagePort)] = [:]
        static func keep(_ pipe: HostPipe, for port: WKWebExtension.MessagePort) {
            let id = ObjectIdentifier(pipe)
            pipes[id] = (pipe, port)
            let previous = pipe.onExit
            pipe.onExit = {
                previous?()
                DispatchQueue.main.async { pipes[id] = nil }
            }
        }
    }
}

/// One host program and the framing Chrome uses to talk to it.
@available(macOS 15.4, *)
final class HostPipe: @unchecked Sendable {
    /// How long a host that has exited may leave its output open (a child
    /// of its own still holding it) before the connection ends anyway.
    static let exitGrace: TimeInterval = 1.5
    /// How long a host has, once asked to stop, before it is killed, as in Chrome.
    static let killGrace: TimeInterval = 2
    /// The most a host may send in one message, as in Chrome; a message to it is held to the same.
    static let frameCap = 1 << 20

    private let program: URL
    private let origin: String
    private var pid: pid_t = 0
    private var reaper: DispatchSourceProcess?
    /// Whether the host still runs, apart from the pipe: the kill timer
    /// reads it without holding the pipe, which is freed once it has ended.
    private let alive = Alive()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private let lock = NSLock()
    /// Held around each use of the input handle, so it is never written once closed.
    private let writing = NSLock()
    var onMessage: ((Any) -> Void)?
    var onExit: (() -> Void)?
    private var waiters: [(id: Int, continuation: CheckedContinuation<Any?, Error>)] = []
    private var nextWaiter = 0
    private var stopped = false
    private var outputClosed = false
    private var finished = false
    private var inputClosed = false
    private var ending = false

    private static var exited: Error { ExtensionNative.Refused(why: "Native host has exited.") }

    init(program: URL, origin: String) {
        self.program = program
        self.origin = origin
        // A host that is already gone — refused to run, killed as it
        // started — would take the browser with it: writing to its closed
        // pipe raises SIGPIPE. Refused, the write only fails.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    /// Spawned the way Chrome spawns a host, not with Process: in this
    /// app's own process group, responsibility disclaimed, working in the
    /// host's folder. Hosts that check who is calling look at exactly that —
    /// 1Password's refuses a host that Process put in a group of its own
    /// ("BrowserSupport was not part of the main browser's tree").
    func start() throws {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, program.deletingLastPathComponent().path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only what the parent has open on purpose reaches the host.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        _ = HostPipe.disclaim?(&attributes, 1)

        // Listened to before it runs: a host may answer at once.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.lock.lock()
                self.outputClosed = true
                self.lock.unlock()
                self.finish()
                // As in Chrome, a host whose output has closed is done with,
                // even if it runs on.
                self.end()
                return
            }
            self.take(chunk)
        }

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(program.path), strdup(origin), nil]
        defer { argv.forEach { free($0) } }
        var child: pid_t = 0
        let status = posix_spawn(&child, program.path, &actions, &attributes, argv, environ)
        guard status == 0 else {
            output.fileHandleForReading.readabilityHandler = nil
            throw ExtensionNative.Refused(why: "Couldn't start the native host (\(status))")
        }
        lock.lock()
        pid = child
        lock.unlock()
        alive.set(true)
        // The host's ends are its own now; with ours of its output closed,
        // its closing that output is what reads as the end.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()

        // A host may exit the moment its last reply is written, before that
        // reply has been read: the end is when its output closes, as in
        // Chrome. But a child of the host's may hold that output open long
        // after, so an exit ends things after a grace in any case.
        let reaper = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit)
        reaper.setEventHandler { [weak self, alive] in
            var status: Int32 = 0
            waitpid(child, &status, 0)
            alive.set(false)
            // Reap even if the one-shot caller has already released its pipe.
            reaper.setEventHandler(handler: nil)
            reaper.cancel()
            guard let self else { return }
            self.lock.lock()
            let now = self.stopped || self.outputClosed
            self.lock.unlock()
            if now {
                self.finish()
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.exitGrace) { [weak self] in self?.finish(); self?.end() }
            }
        }
        reaper.resume()
        self.reaper = reaper
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        if alive.running { end() } else { finish(); end() }
    }

    /// Chrome's call for the same thing: the host, not the browser, is what
    /// macOS asks about camera, contacts and the rest. Private, so looked up.
    private static let disclaim: (@convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32)? = {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
            .map { unsafeBitCast($0, to: (@convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32).self) }
    }()

    func write(_ message: Any) throws {
        let json = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        guard json.count <= Self.frameCap else { throw ExtensionNative.Refused(why: "Message too long for a native host") }
        var length = UInt32(json.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        writing.lock()
        defer { writing.unlock() }
        guard !inputClosed else { throw Self.exited }
        try input.fileHandleForWriting.write(contentsOf: frame)
    }

    func readOne() async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            if wait(continuation) == nil { continuation.resume(throwing: Self.exited) }
        }
    }

    /// Writes `message` and reads the reply. The reply's waiter is in place
    /// before the message goes, so a host quick to answer isn't missed.
    func request(_ message: Any) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            guard let id = wait(continuation) else { return continuation.resume(throwing: Self.exited) }
            do {
                try write(message)
            } catch {
                // Unless a reply or the end got to it first.
                lock.lock()
                let index = waiters.firstIndex { $0.id == id }
                if let index { waiters.remove(at: index) }
                lock.unlock()
                if index != nil { continuation.resume(throwing: error) }
            }
        }
    }

    /// Adds a waiter for the next message, or nil once the connection has ended.
    private func wait(_ continuation: CheckedContinuation<Any?, Error>) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        nextWaiter += 1
        waiters.append((nextWaiter, continuation))
        return nextWaiter
    }

    private func take(_ chunk: Data) {
        lock.lock()
        guard !finished else { return lock.unlock() }
        buffer.append(chunk)
        var messages: [Any] = []
        var overlong = false
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            if length > Self.frameCap { overlong = true; buffer = Data(); break }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: 4..<(4 + length))
            buffer.removeSubrange(0..<(4 + length))
            if let message = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
                messages.append(message)
            }
        }
        var handed: [(CheckedContinuation<Any?, Error>, Any)] = []
        for message in messages where !waiters.isEmpty {
            handed.append((waiters.removeFirst().continuation, message))
        }
        let rest = messages.dropFirst(handed.count)
        let deliver = onMessage
        lock.unlock()
        handed.forEach { $0.0.resume(returning: $0.1) }
        rest.forEach { deliver?($0) }
        // As in Chrome, a host claiming a message past the cap is done with;
        // what it sent before that in the same read is still heard.
        if overlong { finish(); end() }
    }

    /// Stops the host as Chrome does: its input closed and SIGTERM, then
    /// SIGKILL if it is still running after a grace.
    private func end() {
        lock.lock()
        let first = !ending
        ending = true
        let child = alive.running ? pid : 0
        lock.unlock()
        guard first else { return }
        // Off the caller's thread: a write stuck on a host that doesn't read
        // holds `writing` until the signals below free it. A pipe already
        // freed has closed its handles with it.
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            self.writing.lock()
            if !self.inputClosed {
                self.inputClosed = true
                try? self.input.fileHandleForWriting.close()
            }
            self.writing.unlock()
        }
        guard child > 0 else { return }
        kill(child, SIGTERM)
        // Only while it is still the host: once reaped, its pid may be another's.
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) { [alive] in
            if alive.running { kill(child, SIGKILL) }
        }
    }

    private func finish() {
        lock.lock()
        guard !finished else { return lock.unlock() }
        finished = true
        let pending = waiters
        waiters = []
        buffer = Data()
        let exit = onExit
        onExit = nil
        onMessage = nil
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        pending.forEach { $0.continuation.resume(throwing: Self.exited) }
        exit?()
    }
}

/// A host's running, kept apart from its pipe (see HostPipe.alive).
private final class Alive: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var running: Bool { lock.lock(); defer { lock.unlock() }; return on }
    func set(_ value: Bool) { lock.lock(); on = value; lock.unlock() }
}
