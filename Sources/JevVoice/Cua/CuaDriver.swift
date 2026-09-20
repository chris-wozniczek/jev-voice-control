import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

struct CuaResult {
    let structured: JSONValue?
    let text: String?
    let imagePNG: Data?
}

struct CuaApp: Equatable {
    let pid: Int
    let name: String
    let bundleId: String?
}

struct CuaWindow: Equatable {
    let id: Int
    let title: String
    let frame: [String: Double]?
}

struct CuaElement: Equatable {
    let token: String
    let role: String
    let label: String
    let value: String?
}

struct CuaSnapshot {
    let snapshotId: String
    let treeMarkdown: String
    let elements: [CuaElement]
    let image: Data?

    func element(token: String) -> CuaElement? {
        elements.first { $0.token == token }
    }
}

enum CuaDriverError: Error, LocalizedError {
    case unavailable(String)
    case timeout
    case processExited
    case rpc(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .timeout: return "Cua driver request timed out"
        case .processExited: return "Cua driver exited unexpectedly"
        case .rpc(let message): return message
        case .malformedResponse: return "Cua driver returned an invalid response"
        }
    }
}

@MainActor
final class CuaDriver: ObservableObject {
    static let shared = CuaDriver()

    enum State: Equatable {
        case stopped
        case starting
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .stopped

    private var daemon: Process?
    private var mcp: Process?
    private var input: FileHandle?
    private var socketPath: String?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var readerStarted = false
    private var processGeneration = 0

    private init() {}

    func ensureRunning() async throws {
        if state == .ready { return }
        if case .starting = state {
            while true {
                try await Task.sleep(nanoseconds: 50_000_000)
                if state == .ready { return }
                if case .failed(let message) = state {
                    throw CuaDriverError.unavailable(message)
                }
            }
        }

        state = .starting
        processGeneration += 1
        let generation = processGeneration
        do {
            let binary = try driverURL()
            Log.cua.info("spawning cua helper path=\(binary.path, privacy: .public)")
            let socket = FileManager.default.temporaryDirectory
                .appendingPathComponent("jev-cua-\(ProcessInfo.processInfo.processIdentifier).sock")
            try? FileManager.default.removeItem(at: socket)
            socketPath = socket.path

            var environment = ProcessInfo.processInfo.environment
            environment["CUA_DRIVER_EMBEDDED"] = "1"
            environment["CUA_DRIVER_HOST_BUNDLE_ID"] = Bundle.main.bundleIdentifier ?? ""

            let daemon = Process()
            daemon.executableURL = binary
            daemon.arguments = ["serve", "--embedded", "--socket", socket.path]
            daemon.environment = environment
            daemon.standardOutput = FileHandle.standardError
            daemon.standardError = FileHandle.standardError
            daemon.terminationHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.processDidExit(generation: generation)
                }
            }
            try daemon.run()
            self.daemon = daemon

            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: socket.path), Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard FileManager.default.fileExists(atPath: socket.path) else {
                throw CuaDriverError.unavailable("Cua driver socket did not start")
            }

            let mcp = Process()
            let toDriver = Pipe()
            let fromDriver = Pipe()
            mcp.executableURL = binary
            mcp.arguments = ["mcp", "--embedded", "--socket", socket.path]
            mcp.environment = environment
            mcp.standardInput = toDriver
            mcp.standardOutput = fromDriver
            mcp.standardError = FileHandle.standardError
            mcp.terminationHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.processDidExit(generation: generation)
                }
            }
            try mcp.run()
            self.mcp = mcp
            input = toDriver.fileHandleForWriting
            startReader(from: fromDriver.fileHandleForReading, generation: generation)

            _ = try await send(
                method: "initialize",
                params: .object([
                    "protocolVersion": .string("2024-11-05"),
                    "capabilities": .object([:]),
                    "clientInfo": .object([
                        "name": .string("JevVoice"),
                        "version": .string("0.3.1"),
                    ]),
                ])
            )
            try write(.object([
                "jsonrpc": .string("2.0"),
                "method": .string("notifications/initialized"),
            ]))
            state = .ready
            Log.cua.info("cua helper ready socket=\(socket.path, privacy: .public)")
        } catch {
            state = .failed(error.localizedDescription)
            Log.cua.info("cua helper start failed error=\(error.localizedDescription, privacy: .public)")
            shutdown()
            throw error
        }
    }

    func shutdown() {
        Log.cua.info("shutting down cua helper")
        processGeneration += 1
        state = .stopped
        for continuation in pending.values {
            continuation.resume(throwing: CuaDriverError.processExited)
        }
        pending.removeAll()
        input = nil
        if let mcp, mcp.isRunning { mcp.terminate() }
        if let daemon, daemon.isRunning { daemon.terminate() }
        self.mcp = nil
        self.daemon = nil
        readerStarted = false
        if let socketPath { try? FileManager.default.removeItem(atPath: socketPath) }
        socketPath = nil
    }

    func call(_ tool: String, _ args: [String: JSONValue] = [:]) async throws -> CuaResult {
        if state != .ready { try await ensureRunning() }
        let result = try await send(
            method: "tools/call",
            params: .object([
                "name": .string(tool),
                "arguments": .object(args),
            ])
        )
        guard let object = result.objectValue else { throw CuaDriverError.malformedResponse }
        if object["isError"]?.boolValue == true {
            let message = object["content"]?.arrayValue?
                .compactMap { $0.objectValue?["text"]?.stringValue }
                .joined(separator: "\n")
                ?? "Cua tool call failed"
            throw CuaDriverError.rpc(message)
        }
        if let error = object["error"]?.objectValue?["message"]?.stringValue
            ?? object["error"]?.stringValue {
            throw CuaDriverError.rpc(error)
        }
        let structured = object["structuredContent"]
        var textParts: [String] = []
        var image: Data?
        if let content = object["content"]?.arrayValue {
            for item in content {
                guard let item = item.objectValue else { continue }
                if item["type"]?.stringValue == "text", let text = item["text"]?.stringValue {
                    textParts.append(text)
                } else if item["type"]?.stringValue == "image",
                          let data = item["data"]?.stringValue {
                    image = Data(base64Encoded: data)
                }
            }
        }
        return CuaResult(
            structured: structured,
            text: textParts.isEmpty ? nil : textParts.joined(separator: "\n"),
            imagePNG: image
        )
    }

    func apps() async throws -> [CuaApp] {
        let result = try await call("list_apps")
        let records = result.structured?["apps"]?.arrayValue ?? []
        let apps: [CuaApp] = records.compactMap { value in
            guard let object = value.objectValue, let pid = object["pid"]?.intValue,
                  let name = object["name"]?.stringValue else { return nil }
            return CuaApp(pid: pid, name: name, bundleId: object["bundle_id"]?.stringValue)
        }
        Log.cua.info("apps count=\(apps.count)")
        return apps
    }

    func windows(pid: Int) async throws -> [CuaWindow] {
        let result = try await call("list_windows", ["pid": .number(Double(pid))])
        let records = result.structured?["windows"]?.arrayValue ?? []
        let windows: [CuaWindow] = records.compactMap { value in
            guard let object = value.objectValue, let id = object["window_id"]?.intValue else {
                return nil
            }
            let frame = object["bounds"]?.objectValue?.reduce(into: [String: Double]()) {
                if case .number(let value) = $1.value { $0[$1.key] = value }
            }
            return CuaWindow(id: id, title: object["title"]?.stringValue ?? "", frame: frame)
        }
        Log.cua.info("windows pid=\(pid) count=\(windows.count)")
        return windows
    }

    func windowState(pid: Int, windowId: Int, includeImage: Bool = true) async throws -> CuaSnapshot {
        let result = try await call("get_window_state", [
            "pid": .number(Double(pid)),
            "window_id": .number(Double(windowId)),
            "include_screenshot": .bool(includeImage),
        ])
        let object = result.structured?.objectValue ?? [:]
        let elements = (object["elements"]?.arrayValue ?? []).compactMap { value -> CuaElement? in
            guard let item = value.objectValue,
                  let token = item["element_token"]?.stringValue else { return nil }
            return CuaElement(
                token: token,
                role: item["role"]?.stringValue ?? "",
                label: item["label"]?.stringValue ?? "",
                value: item["value"]?.stringValue
            )
        }
        return CuaSnapshot(
            snapshotId: object["snapshot_id"]?.stringValue ?? "",
            treeMarkdown: object["tree_markdown"]?.stringValue ?? "",
            elements: elements,
            image: result.imagePNG
        )
    }

    func click(pid: Int, token: String) async throws -> CuaResult {
        try await call("click", [
            "pid": .number(Double(pid)),
            "element_token": .string(token),
        ])
    }

    func click(pid: Int, windowId: Int, x: Double, y: Double) async throws -> CuaResult {
        try await call("click", [
            "pid": .number(Double(pid)),
            "window_id": .number(Double(windowId)),
            "x": .number(x),
            "y": .number(y),
        ])
    }

    func type(
        pid: Int,
        text: String,
        token: String? = nil,
        windowId: Int? = nil
    ) async throws -> CuaResult {
        var args: [String: JSONValue] = [
            "pid": .number(Double(pid)),
            "text": .string(text),
        ]
        if let token { args["element_token"] = .string(token) }
        if let windowId { args["window_id"] = .number(Double(windowId)) }
        return try await call("type_text", args)
    }

    func pressKey(
        pid: Int,
        key: String,
        modifiers: [String] = [],
        windowId: Int? = nil
    ) async throws -> CuaResult {
        var args: [String: JSONValue] = [
            "pid": .number(Double(pid)),
            "key": .string(key),
            "modifiers": .array(modifiers.map(JSONValue.string)),
        ]
        if let windowId { args["window_id"] = .number(Double(windowId)) }
        return try await call("press_key", args)
    }

    private func driverURL() throws -> URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/cua-driver").path
        let path = ProcessInfo.processInfo.environment["CUA_DRIVER_PATH"] ?? bundled
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw CuaDriverError.unavailable("Bundled cua-driver is not available")
        }
        return URL(fileURLWithPath: path)
    }

    private func write(_ value: JSONValue) throws {
        guard let input else { throw CuaDriverError.processExited }
        let data = try JSONEncoder().encode(value) + Data([0x0A])
        input.write(data)
    }

    private func send(method: String, params: JSONValue) async throws -> JSONValue {
        nextID += 1
        let id = nextID
        let started = Date()
        Log.cua.info("request method=\(method, privacy: .public)")
        let request = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.failPending(id: id, error: CuaDriverError.timeout)
        }
        defer { timeoutTask.cancel() }
        do {
            let result = try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try write(request)
                } catch {
                    pending.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
            Log.cua.info(
                "request method=\(method, privacy: .public) elapsed=\(Date().timeIntervalSince(started))"
            )
            return result
        } catch {
            Log.cua.info(
                "request method=\(method, privacy: .public) error=\(error.localizedDescription, privacy: .public) elapsed=\(Date().timeIntervalSince(started))"
            )
            throw error
        }
    }

    private func failPending(id: Int, error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    private func processDidExit(generation: Int) {
        guard generation == processGeneration, state != .stopped else { return }
        Log.cua.info("cua helper exited unexpectedly")
        for continuation in pending.values {
            continuation.resume(throwing: CuaDriverError.processExited)
        }
        pending.removeAll()
        input = nil
        mcp = nil
        daemon = nil
        readerStarted = false
        if let socketPath {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        socketPath = nil
        state = .failed("Cua driver exited unexpectedly")
    }

    private func startReader(from handle: FileHandle, generation: Int) {
        guard !readerStarted else { return }
        readerStarted = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    Task { @MainActor [weak self] in
                        self?.processDidExit(generation: generation)
                    }
                    return
                }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard !line.isEmpty,
                          let value = try? JSONDecoder().decode(JSONValue.self, from: line),
                          let id = value["id"]?.intValue else { continue }
                    Task { @MainActor [weak self] in
                        guard let self, let continuation = self.pending.removeValue(forKey: id) else {
                            return
                        }
                        if let error = value["error"]?.objectValue,
                           let message = error["message"]?.stringValue {
                            continuation.resume(throwing: CuaDriverError.rpc(message))
                        } else if let result = value["result"] {
                            continuation.resume(returning: result)
                        } else {
                            continuation.resume(throwing: CuaDriverError.malformedResponse)
                        }
                    }
                }
            }
        }
    }
}
