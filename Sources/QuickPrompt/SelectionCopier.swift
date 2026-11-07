import AppKit
import ApplicationServices
import Carbon

/// The outcome of trying to copy the selection.
enum CopyOutcome {
    case text(String)
    /// The clipboard did not change: nothing was selected, or the application ignored Command-C.
    case nothingSelected
    /// Another application came to the front during the wait, so nothing was sent.
    case applicationChanged
    /// A newer shortcut press replaced this one.
    case cancelled
}

/// Copies the current selection of the frontmost application by sending Command-C.
enum SelectionCopier {
    /// Reflects the Accessibility switch in System Settings without restarting the app.
    static var hasPermission: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Copies the selection of `targetApp`. Stops without sending anything when the attempt is cancelled
    /// or another application comes to the front during the deliberate wait.
    @MainActor
    static func copySelection(attempt: Int, releaseKey: CGKeyCode, targetApp: pid_t?) async -> CopyOutcome {
        let started = Date()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        let heldAtStart = CGEventSource.flagsState(.combinedSessionState)

        // Measured (33 attempts, Telegram): a Command-C sent within about 0.1 s of the shortcut is usually
        // ignored (5 of 17 copied), from 0.12 s on it always worked (16 of 16), even with Shift and Command
        // still held. An earlier run showed that a physically held shortcut key (for example C) also blocks the
        // copy. So: wait up to one second until that key is released, and send no earlier than `minDelayMs`
        // after the shortcut. The delay can be raised without a rebuild:
        //   defaults write io.github.maximnikmazin.quickprompt minDelayMs -int 300
        let minimumDelay = UserDefaults.standard.object(forKey: "minDelayMs") as? Int ?? 200
        var waitedForKeys = 0
        do {
            while waitedForKeys < 1000, CGEventSource.keyState(.combinedSessionState, key: releaseKey) {
                try await Task.sleep(for: .milliseconds(10))
                waitedForKeys += 10
            }
            let remaining = minimumDelay - Int(Date().timeIntervalSince(started) * 1000)
            if remaining > 0 {
                try await Task.sleep(for: .milliseconds(remaining))
            }
        } catch {
            Log.write("#\(attempt) cancelled before sending Command-C")
            return .cancelled
        }
        if let targetApp, NSWorkspace.shared.frontmostApplication?.processIdentifier != targetApp {
            Log.write("#\(attempt) app changed during the wait; nothing sent")
            return .applicationChanged
        }
        let heldWhenSent = modifiers(CGEventSource.flagsState(.combinedSessionState))
        let downWhenSent = keysDown()

        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let sentAt = Date()
        let sentAfter = Int(sentAt.timeIntervalSince(started) * 1000)
        // A private event source does not mix in the keys the person is physically holding.
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

        var text: String?
        var changedAfter = -1
        for _ in 0..<50 {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                Log.write("#\(attempt) cancelled while waiting for the clipboard")
                return .cancelled
            }
            if pasteboard.changeCount != before {
                changedAfter = Int(Date().timeIntervalSince(sentAt) * 1000)
                text = pasteboard.string(forType: .string)
                break
            }
        }

        Log.write("#\(attempt) app=\(front) minDelayMs=\(minimumDelay) sentAfterMs=\(sentAfter) heldAtStart=\(modifiers(heldAtStart)) waitedForKeysMs=\(waitedForKeys) "
            + "atSend[modifiers=\(heldWhenSent) keysDown=\(downWhenSent.isEmpty ? "none" : downWhenSent)] clipboardChanged=\(changedAfter >= 0 ? "yes after \(changedAfter)ms" : "NO within 1000ms") "
            + "characters=\(text?.count ?? 0)")
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text(text) }
        return .nothingSelected
    }
}

/// Key codes currently held down, for example "8" for C. Modifier keys are reported by `modifiers`.
private func keysDown() -> String {
    let modifierCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    return (0..<128).filter { !modifierCodes.contains($0) && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }
        .map { $0 == 8 ? "C" : String($0) }
        .joined(separator: ",")
}

extension SelectionCopier {
    /// Pastes the clipboard into the frontmost application by sending Command-V.
    static func paste() {
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}

private func modifiers(_ flags: CGEventFlags) -> String {
    var parts: [String] = []
    if flags.contains(.maskControl) { parts.append("Ctrl") }
    if flags.contains(.maskAlternate) { parts.append("Opt") }
    if flags.contains(.maskShift) { parts.append("Shift") }
    if flags.contains(.maskCommand) { parts.append("Cmd") }
    return parts.isEmpty ? "none" : parts.joined(separator: "+")
}

/// A small diagnostic log in ~/Library/Logs/QuickPrompt.log. It never records the text itself.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/QuickPrompt.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
