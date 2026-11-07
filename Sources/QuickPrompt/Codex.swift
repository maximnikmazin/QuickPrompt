import Foundation

// MARK: - Codex

/// Runs prompts through the installed Codex command-line tool, signed in with the person's ChatGPT plan.
///
/// One `codex app-server` process stays running and talks JSON-RPC over standard input and output, the way the
/// Codex editor extensions do. For each model and instruction that has been used, one conversation ("thread") is
/// started ahead of time, so the next request only sends its text. Codex's own coding instructions are replaced
/// by the action's instruction, and AGENTS.md files, tools, plugins and MCP servers are switched off, because
/// each of them adds seconds to every answer. The Fast service tier is never requested: it uses up the plan's
/// limits much faster.
@MainActor
final class CodexRunner {
    /// Codex models are stored in the actions file as "codex:<model id>", for example "codex:gpt-6-luna".
    nonisolated static let prefix = "codex:"
    nonisolated static func isCodex(_ model: String) -> Bool { model.hasPrefix(prefix) }
    nonisolated static func modelID(_ model: String) -> String { String(model.dropFirst(prefix.count)) }
    /// A short name for a Codex model: "codex:gpt-6.1-sol" becomes "6.1 Sol".
    nonisolated static func shortName(_ model: String) -> String {
        var id = modelID(model)
        if id.lowercased().hasPrefix("gpt-") { id = String(id.dropFirst(4)) }
        return id.split(separator: "-").map { part in
            part.first?.isLetter == true ? part.prefix(1).uppercased() + part.dropFirst() : String(part)
        }.joined(separator: " ")
    }

    private static let maximumWarm = 3

    private var server: CodexServer?
    private var starting: Task<CodexServer, Error>?
    /// Threads started ahead of time, waiting for their message, by model and instruction.
    private var warm: [String: String] = [:]
    private var warming: Set<String> = []

    private static func key(_ model: String, _ system: String) -> String { model + "\u{0}" + system }

    /// Whether the Codex command-line tool can be found on this Mac.
    var isInstalled: Bool { (try? CodexServer.executable()) != nil }

    private func liveServer() async throws -> CodexServer {
        if let server, server.isRunning { return server }
        if let starting { return try await starting.value }
        warm = [:]
        let task = Task { () throws -> CodexServer in
            let started = try await CodexServer.start()
            try await started.initialize()
            // The first answer after a start waited about 10 seconds while Codex loaded the account; asking for
            // it right away moves that wait to before the shortcut.
            _ = try? await started.request("account/read", ["refreshToken": false])
            return started
        }
        starting = task
        defer { starting = nil }
        let started = try await task.value
        server = started
        return started
    }

    /// The models the signed-in account can use, as "codex:<id>" with their display names.
    func listModels() async throws -> [(model: String, name: String)] {
        let server = try await liveServer()
        let result = try await server.request("model/list", [:])
        let data = result["data"] as? [[String: Any]] ?? []
        return data.compactMap { item in
            guard let id = item["id"] as? String, (item["hidden"] as? Bool) != true else { return nil }
            return (Self.prefix + id, item["displayName"] as? String ?? id)
        }
    }

    func prewarm(model: String, system: String) {
        let key = Self.key(model, system)
        guard warm[key] == nil, !warming.contains(key) else { return }
        warming.insert(key)
        Task {
            defer { warming.remove(key) }
            guard let server = try? await liveServer(),
                  let thread = try? await startThread(server, model: model, system: system) else { return }
            warm[key] = thread
            while warm.count > Self.maximumWarm, let other = warm.keys.first(where: { $0 != key }) {
                warm[other] = nil
            }
        }
    }

    /// Forgets waiting threads whose model and instruction no longer belong to any action, and stops Codex
    /// when no action uses it.
    func keepOnly(_ pairs: [(model: String, system: String)]) {
        let wanted = Set(pairs.map { Self.key($0.model, $0.system) })
        warm = warm.filter { wanted.contains($0.key) }
        if pairs.isEmpty { shutdown() }
    }

    func shutdown() {
        server?.terminate()
        server = nil
        warm = [:]
    }

    private func startThread(_ server: CodexServer, model: String, system: String) async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickPrompt-codex")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await server.request("thread/start", [
            "model": Self.modelID(model),
            "cwd": directory.path,
            "approvalPolicy": "never",
            "sandbox": "read-only",
            // Not saved in the person's Codex history.
            "ephemeral": true,
            "baseInstructions": system,
        ])
        guard let thread = (result["thread"] as? [String: Any])?["id"] as? String else {
            throw TranslationFailure(message: "Codex did not start a conversation.")
        }
        return thread
    }

    func run(model: String, system: String, message: String, timeout: Duration,
             onPartial: @escaping @MainActor (String) -> Void) async throws -> ModelAnswer {
        let server = try await liveServer()
        let key = Self.key(model, system)
        let thread: String
        if let ready = warm.removeValue(forKey: key) {
            thread = ready
        } else {
            thread = try await startThread(server, model: model, system: system)
        }
        defer { prewarm(model: model, system: system) }

        let events = server.events(for: thread)
        defer { server.endEvents(for: thread) }
        let turnResult = try await server.request("turn/start", [
            "threadId": thread,
            "effort": "low",
            "input": [["type": "text", "text": message, "text_elements": [Any]()]],
        ])
        let turn = (turnResult["turn"] as? [String: Any])?["id"] as? String ?? ""

        let watchdog = Task {
            try await Task.sleep(for: timeout)
            server.notify("turn/interrupt", ["threadId": thread, "turnId": turn])
        }
        defer { watchdog.cancel() }

        return try await withTaskCancellationHandler {
            var streamed = ""
            var lastError: String?
            for await event in events {
                let params = event["params"] as? [String: Any] ?? [:]
                switch event["method"] as? String {
                case "item/agentMessage/delta":
                    streamed += params["delta"] as? String ?? ""
                    onPartial(streamed)
                case "error":
                    if (params["willRetry"] as? Bool) != true {
                        lastError = Self.describe((params["error"] as? [String: Any]) ?? [:])
                    }
                case "turn/completed":
                    let turn = params["turn"] as? [String: Any] ?? [:]
                    let finalText = (turn["items"] as? [[String: Any]] ?? [])
                        .filter { $0["type"] as? String == "agentMessage" }
                        .compactMap { $0["text"] as? String }.last
                    switch turn["status"] as? String {
                    case "completed":
                        return ModelAnswer(text: Self.clean(finalText ?? streamed), model: Self.modelID(model),
                                           isComplete: true)
                    case "interrupted":
                        if !streamed.isEmpty {
                            return ModelAnswer(text: Self.clean(streamed), model: nil, isComplete: false)
                        }
                        throw TranslationFailure(message: "Codex stopped without an answer (time limit reached).")
                    default:
                        let error = Self.describe((turn["error"] as? [String: Any]) ?? [:])
                        throw TranslationFailure(message: lastError ?? error)
                    }
                default:
                    break
                }
            }
            throw TranslationFailure(message: server.stoppedMessage)
        } onCancel: {
            Task { @MainActor in server.notify("turn/interrupt", ["threadId": thread, "turnId": turn]) }
        }
    }

    /// A readable message for a Codex error, with the next step for the common cases.
    private static func describe(_ error: [String: Any]) -> String {
        let message = error["message"] as? String ?? "Codex could not answer."
        // Signed out, Codex reports "unexpected status 401 Unauthorized" without the "unauthorized" code.
        let unauthorized = message.contains("401") || message.localizedCaseInsensitiveContains("unauthorized")
        switch unauthorized ? "unauthorized" : error["codexErrorInfo"] as? String {
        case "unauthorized":
            return "Codex is not signed in. Run `codex login` in Terminal, then try again."
        case "usageLimitExceeded", "rateLimitExceeded":
            return "Codex: the usage limit of your plan is reached. \(message)"
        default:
            return "Codex: \(message)"
        }
    }

    private static func clean(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("<text>") && result.hasSuffix("</text>") {
            result = String(result.dropFirst(6).dropLast(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}

/// One running `codex app-server` process and its JSON-RPC connection.
@MainActor
final class CodexServer {
    private let process: Process
    private let input: FileHandle
    private let errorTail = OutputTail()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var streams: [String: AsyncStream<[String: Any]>.Continuation] = [:]

    var isRunning: Bool { process.isRunning }

    var stoppedMessage: String {
        let details = errorTail.text
        return details.isEmpty ? "Codex stopped unexpectedly." : "Codex: \(details.prefix(300))"
    }

    /// Codex features that add tools, plugins or instructions to every request; switched off when this version
    /// of Codex knows them (an unknown name stops Codex from starting).
    nonisolated private static let unwantedFeatures = [
        "multi_agent", "skill_search", "plugins", "remote_plugin", "apps", "browser_use", "computer_use",
        "image_generation", "goals", "shell_tool", "unified_exec", "view_image", "sleep_tool", "tool_suggest",
        "workspace_dependencies", "memories",
    ]

    nonisolated static func executable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          "\(home)/.npm-global/bin/codex", "\(home)/.bun/bin/codex"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw TranslationFailure(message: "Codex is not installed. Install it with `npm install -g @openai/codex` "
                + "and run `codex login`, or choose a Claude model for this action in Settings.")
        }
        return URL(fileURLWithPath: path)
    }

    /// The environment for Codex: a Finder-launched app has a short PATH, and an npm-installed Codex needs node.
    nonisolated private static func environment(for executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extra = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        return environment
    }

    /// Feature names this version of Codex accepts, from `codex features list`.
    nonisolated private static func knownFeatures(_ executable: URL) -> Set<String> {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["features", "list"]
        process.environment = environment(for: executable)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var names: Set<String> = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            if columns.count >= 2, !line.contains("removed") { names.insert(String(columns[0])) }
        }
        return names
    }

    /// MCP servers from the person's Codex settings. Codex starts them for every conversation and waits for
    /// them before answering, so each one is replaced by a disabled entry for this app only.
    nonisolated private static func mcpServerOverrides() -> [String] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        guard let text = try? String(contentsOfFile: home + "/config.toml", encoding: .utf8) else { return [] }
        var names: [String] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[mcp_servers."), trimmed.hasSuffix("]") else { continue }
            let rest = trimmed.dropFirst("[mcp_servers.".count).dropLast()
            let name: String
            if rest.hasPrefix("\"") {
                name = String(rest.dropFirst().prefix { $0 != "\"" })
            } else {
                name = String(rest.prefix { $0 != "." })
            }
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names.flatMap { name -> [String] in
            let bare = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            let key = bare ? name : "\"\(name.replacingOccurrences(of: "\"", with: "\\\""))\""
            return ["-c", "mcp_servers.\(key)={command=\"/usr/bin/true\",enabled=false}"]
        }
    }

    static func start() async throws -> CodexServer {
        let executable = try executable()
        let known = await Task.detached { knownFeatures(executable) }.value
        var arguments = ["app-server",
                         "-c", "project_doc_max_bytes=0",
                         "-c", "web_search=\"disabled\"",
                         "-c", "skills.include_instructions=false",
                         "-c", "agents.enabled=false",
                         "-c", "include_environment_context=false",
                         "-c", "include_permissions_instructions=false",
                         "-c", "include_apps_instructions=false",
                         "-c", "include_collaboration_mode_instructions=false",
                         "-c", "suppress_unstable_features_warning=true"]
        for feature in unwantedFeatures where known.contains(feature) {
            arguments += ["--disable", feature]
        }
        if known.contains("skip_host_skill_discovery") { arguments += ["--enable", "skip_host_skill_discovery"] }
        arguments += mcpServerOverrides()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment(for: executable)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickPrompt-codex")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.currentDirectoryURL = directory
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let server = CodexServer(process: process, input: input.fileHandleForWriting)
        let tail = server.errorTail
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { tail.append(data) }
        }
        let reader = output.fileHandleForReading
        Task { @MainActor [weak server] in
            do {
                for try await line in reader.bytes.lines { server?.receive(line) }
            } catch {}
            server?.connectionEnded()
        }
        return server
    }

    private init(process: Process, input: FileHandle) {
        self.process = process
        self.input = input
    }

    func initialize() async throws {
        _ = try await request("initialize", ["clientInfo": ["name": "quickprompt", "title": "QuickPrompt",
                                                            "version": "1.0"]])
        notify("initialized", [:])
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(["id": id, "method": method, "params": params])
            } catch {
                pending[id] = nil
                continuation.resume(throwing: TranslationFailure(message: stoppedMessage))
            }
        }
    }

    func notify(_ method: String, _ params: [String: Any]) {
        try? send(["method": method, "params": params])
    }

    /// Notifications for one conversation, until `endEvents(for:)` or until Codex stops.
    func events(for thread: String) -> AsyncStream<[String: Any]> {
        AsyncStream { continuation in streams[thread] = continuation }
    }

    func endEvents(for thread: String) {
        streams.removeValue(forKey: thread)?.finish()
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(_ line: String) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
        let method = message["method"] as? String
        if let id = message["id"] as? Int, method == nil {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: TranslationFailure(
                    message: "Codex: \(error["message"] as? String ?? "request failed")"))
            } else {
                continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
            }
        } else if let id = message["id"], method != nil {
            // Codex asks for approvals only when a tool wants to run; tools are off, so every request is declined.
            try? send(["id": id, "error": ["code": -32601, "message": "Not supported by QuickPrompt"]])
        } else if let thread = (message["params"] as? [String: Any])?["threadId"] as? String {
            streams[thread]?.yield(message)
        }
    }

    private func connectionEnded() {
        let failure = TranslationFailure(message: stoppedMessage)
        pending.values.forEach { $0.resume(throwing: failure) }
        pending = [:]
        streams.values.forEach { $0.finish() }
        streams = [:]
    }
}
