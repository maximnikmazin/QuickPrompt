import Foundation
import NaturalLanguage
import Translation

/// Which way a text is translated: into the person's own language, or into English when the text is already in it.
/// The person's own language is the first language in System Settings → General → Language & Region → Preferred
/// Languages that is not English; English when the list has only English.
struct Direction {
    let sourceCode: String
    let targetCode: String

    var targetName: String { Self.name(targetCode) }
    var label: String { "\(Self.base(sourceCode).uppercased()) → \(Self.base(targetCode).uppercased())" }
    var isSameLanguage: Bool { Self.base(sourceCode) == Self.base(targetCode) }

    /// The person's own language as a code that Apple Translation accepts, for example "ru", "de" or "zh-Hans".
    static var home: String {
        for identifier in Locale.preferredLanguages where base(identifier) != "en" {
            return code(identifier)
        }
        return "en"
    }

    /// The language's English name, for example "Russian" or "Chinese, Simplified".
    static func name(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }

    static func detect(_ text: String, home: String = Direction.home) -> Direction {
        let homeBase = base(home)
        // Russian text often contains English words; more Cyrillic than Latin letters counts as Russian.
        if homeBase == "ru" {
            let cyrillic = text.unicodeScalars.filter { (0x0400...0x04FF).contains($0.value) }.count
            let latin = text.unicodeScalars.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }.count
            if cyrillic > latin { return Direction(sourceCode: "ru", targetCode: "en") }
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let detected = recognizer.dominantLanguage?.rawValue ?? "en"
        if base(detected) == homeBase {
            return Direction(sourceCode: home, targetCode: "en")
        }
        return Direction(sourceCode: detected, targetCode: home)
    }

    /// "zh-Hans" or "zh-Hant" for Chinese, otherwise the bare language code ("ru-RU" → "ru").
    private static func code(_ identifier: String) -> String {
        let language = Locale.Language(identifier: identifier)
        guard let languageCode = language.languageCode?.identifier else { return identifier }
        guard languageCode == "zh" else { return languageCode }
        return language.maximalIdentifier.contains("Hant") ? "zh-Hant" : "zh-Hans"
    }

    static func base(_ identifier: String) -> String {
        Locale.Language(identifier: identifier).languageCode?.identifier ?? identifier
    }
}

struct TranslationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Apple Translation

/// On-device translation with the language models downloaded in System Settings.
@MainActor
final class AppleTranslator {
    private var sessions: [String: TranslationSession] = [:]

    func translate(_ text: String, direction: Direction) async throws -> String {
        if direction.isSameLanguage {
            throw TranslationFailure(message: "The text is already in \(direction.targetName). To translate English text, "
                + "add your language to System Settings → General → Language & Region → Preferred Languages.")
        }
        // The system translation service quits after a few idle minutes. Right after it starts again, the first
        // request (and macOS's own availability check) can report a missing language pack although it is installed;
        // a request a few seconds later works. So a "not installed" answer is tried again twice before it is shown.
        var lastError: Error?
        for delay in [0, 1000, 2000] {
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            do {
                let result = try await attempt(text, direction: direction)
                if delay > 0 { Log.write("apple translation worked on retry after \(delay) ms") }
                return result
            } catch where String(describing: error).contains("notInstalled") {
                lastError = error
            } catch {
                throw TranslationFailure(message: "Apple Translation failed: \(error.localizedDescription)")
            }
        }
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: direction.sourceCode),
                                                         to: Locale.Language(identifier: direction.targetCode))
        Log.write("apple translation still notInstalled; availability=\(status) \(String(describing: lastError).prefix(120))")
        throw TranslationFailure(message: "Apple Translation has no \(direction.label) language pack. "
            + "Download it in System Settings → General → Language & Region → Translation Languages.")
    }

    private func attempt(_ text: String, direction: Direction) async throws -> String {
        let key = "\(direction.sourceCode)>\(direction.targetCode)"
        let session = sessions[key] ?? TranslationSession(
            installedSource: Locale.Language(identifier: direction.sourceCode),
            target: Locale.Language(identifier: direction.targetCode))
        sessions[key] = session
        do {
            return try await session.translate(text).targetText
        } catch {
            sessions[key] = nil
            Log.write("apple translation error: \(String(describing: error).prefix(300))")
            throw error
        }
    }
}

// MARK: - Claude Code

/// An answer from Claude or Codex and the full name of the model that produced it, for example "claude-sonnet-5".
struct ModelAnswer {
    let text: String
    let model: String?
    /// False when the answer stopped before Claude finished, for example at the time limit.
    let isComplete: Bool
}

/// Runs prompts through the installed Claude Code command-line tool, signed in with the person's
/// subscription. For each model and instruction that has been used, one process is started ahead of time
/// and waits for its single message on standard input, so the start-up cost is paid before the shortcut.
@MainActor
final class ClaudeRunner {
    /// The default instruction of the Translate action; the person can edit it in the settings.
    nonisolated static let translationPrompt = DefaultInstructions.translate

    private static let maximumWarm = 3

    /// Processes started ahead of time, waiting for their message, by model and instruction.
    private var warm: [String: ClaudeProcess] = [:]
    /// Processes answering a request right now; stopped when the app quits.
    private var active: [ObjectIdentifier: ClaudeProcess] = [:]
    private var cleanupTimer: Timer?

    init() {
        // Waiting processes older than their idle limit are stopped once a minute, not only when reused.
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropStale() }
        }
    }

    private static func key(_ model: String, _ system: String) -> String { model + "\u{0}" + system }

    func prewarm(model: String, system: String) {
        let key = Self.key(model, system)
        if let process = warm[key], process.isFresh { return }
        warm[key]?.terminate()
        warm[key] = try? ClaudeProcess.start(model: model, system: system)
        // Keep at most a few waiting processes; stop the oldest.
        while warm.count > Self.maximumWarm, let oldest = warm.min(by: { $0.value.started < $1.value.started }) {
            oldest.value.terminate()
            warm[oldest.key] = nil
        }
    }

    /// Stops waiting processes whose model and instruction no longer belong to any action.
    func keepOnly(_ pairs: [(model: String, system: String)]) {
        let wanted = Set(pairs.map { Self.key($0.model, $0.system) })
        for (key, process) in warm where !wanted.contains(key) {
            process.terminate()
            warm[key] = nil
        }
    }

    private func dropStale() {
        for (key, process) in warm where !process.isFresh {
            process.terminate()
            warm[key] = nil
        }
    }

    /// Stops every waiting and every running process, for example when the app quits.
    func shutdown() {
        warm.values.forEach { $0.terminate() }
        active.values.forEach { $0.terminate() }
        warm = [:]
        active = [:]
    }

    func run(model: String, system: String, message: String, timeout: Duration,
             onPartial: @escaping @MainActor (String) -> Void) async throws -> ModelAnswer {
        let key = Self.key(model, system)
        let process: ClaudeProcess
        if let ready = warm[key], ready.isFresh {
            process = ready
        } else {
            warm[key]?.terminate()
            process = try ClaudeProcess.start(model: model, system: system)
        }
        warm[key] = nil
        prewarm(model: model, system: system)
        let id = ObjectIdentifier(process)
        active[id] = process
        defer { active[id] = nil }
        return try await process.run(prompt: message, timeout: timeout, onPartial: onPartial)
    }
}

final class ClaudeProcess {
    private static let maximumIdle: TimeInterval = 15 * 60

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let errors: Pipe
    let started = Date()
    /// The last few kilobytes of the tool's error output, read as it arrives so the pipe never fills up.
    private let errorTail = OutputTail()

    var isFresh: Bool { process.isRunning && Date().timeIntervalSince(started) < Self.maximumIdle }

    private init(process: Process, input: FileHandle, output: FileHandle, errors: Pipe) {
        self.process = process
        self.input = input
        self.output = output
        self.errors = errors
        let tail = errorTail
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { tail.append(data) }
        }
    }

    static func executable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw TranslationFailure(message: "Claude Code is not installed. Install it from claude.com/claude-code and "
                + "sign in with your Claude subscription, or choose another model for this action in Settings.")
        }
        return URL(fileURLWithPath: path)
    }

    static func start(model: String, system: String) throws -> ClaudeProcess {
        let process = Process()
        process.executableURL = try executable()
        process.arguments = [
            "-p",
            "--model", model,
            "--system-prompt", system,
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--disable-slash-commands",
            "--exclude-dynamic-system-prompt-sections",
            "--no-session-persistence",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC")
        }
        environment["MAX_THINKING_TOKENS"] = "0"
        process.environment = environment

        // An empty working directory, so that no project instructions are discovered.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickPrompt-claude")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.currentDirectoryURL = directory

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        return ClaudeProcess(process: process, input: input.fileHandleForWriting,
                             output: output.fileHandleForReading, errors: errors)
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    deinit {
        errors.fileHandleForReading.readabilityHandler = nil
    }

    func run(prompt: String, timeout: Duration, onPartial: @escaping @MainActor (String) -> Void) async throws -> ModelAnswer {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": prompt]]
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.write(contentsOf: data)
        try input.close()

        let watchdog = Task { [process] in
            try await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }

        return try await withTaskCancellationHandler {
            var streamed = ""
            for try await line in output.bytes.lines {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                switch event["type"] as? String {
                case "stream_event":
                    if let inner = event["event"] as? [String: Any],
                       let delta = inner["delta"] as? [String: Any],
                       delta["type"] as? String == "text_delta",
                       let text = delta["text"] as? String {
                        streamed += text
                        let snapshot = streamed
                        await onPartial(snapshot)
                    }
                case "result":
                    let result = (event["result"] as? String) ?? streamed
                    if (event["is_error"] as? Bool) == true {
                        // Signed out, Claude Code answers "Not logged in · Please run /login" or "Invalid API key".
                        if result.contains("/login") || result.localizedCaseInsensitiveContains("not logged in")
                            || result.localizedCaseInsensitiveContains("invalid api key") {
                            throw TranslationFailure(message: "Claude Code is not signed in. Run `claude` in Terminal, "
                                + "sign in with your Claude subscription, then try again.")
                        }
                        throw TranslationFailure(message: "Claude: \(result)")
                    }
                    let model = (event["modelUsage"] as? [String: Any])?.keys.sorted().first
                    return ModelAnswer(text: Self.clean(result), model: model, isComplete: true)
                default:
                    break
                }
            }
            // The output ended without Claude's final message: the answer was cut off.
            if !streamed.isEmpty { return ModelAnswer(text: Self.clean(streamed), model: nil, isComplete: false) }
            let details = errorTail.text
            throw TranslationFailure(message: details.isEmpty
                ? "Claude stopped without an answer (time limit reached or the process was closed)."
                : "Claude: \(details.prefix(300))")
        } onCancel: { [process] in
            if process.isRunning { process.terminate() }
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

/// The last few kilobytes of a tool's error output, read as it arrives so the pipe never fills up.
final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > 8192 { data = data.suffix(8192) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
