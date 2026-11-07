import AppKit
import Carbon
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var hotKeys: [HotKey] = []
    private var registeredShortcuts: [String] = []
    private var attempts = 0
    private let popup = NotchPopup()
    private let apple = AppleTranslator()
    private let claude = ClaudeRunner()
    private let codex = CodexRunner()
    private var currentTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        state.onShortcutsChanged = { [weak self] in self?.applySettings() }
        state.onRecordingStarted = { [weak self] in self?.releaseShortcuts() }
        state.onPreview = { [weak self] in self?.showPreview() }
        applySettings()

        let arguments = CommandLine.arguments
        // `--demo <text>` shows a finished popup without copying anything, for screenshots.
        if let index = arguments.firstIndex(of: "--demo"), index + 1 < arguments.count {
            popup.showWorking(label: "Claude · EN → RU")
            popup.showResult(arguments[index + 1])
            if let snapshot = arguments.firstIndex(of: "--snapshot"), snapshot + 1 < arguments.count {
                let path = arguments[snapshot + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [popup] in
                    MainActor.assumeIsolated { popup.writeSnapshot(to: path) }
                }
            }
            return
        }
        // `--demo-action <action name> <model> <text>` runs an action three times with another model (for example
        // codex:gpt-6-luna) on the given text, shows the popup and prints the times; nothing is copied or saved.
        if let index = arguments.firstIndex(of: "--demo-action"), index + 3 < arguments.count,
           var action = state.file.actions.first(where: { $0.name == arguments[index + 1] }) {
            action.model = arguments[index + 2]
            let text = arguments[index + 3]
            popup.demoFrameLog = true
            Task { @MainActor in
                // As at launch: Codex actions are prepared in advance, then the person presses the shortcut later.
                if CodexRunner.isCodex(action.model) {
                    codex.prewarm(model: action.model, system: instruction(for: action))
                    try? await Task.sleep(for: .seconds(12))
                }
                for round in 1...3 {
                    popup.beginAttempt()
                    let direction = action.isTranslation ? Direction.detect(text) : nil
                    popup.showWorking(label: "\(action.name) · \(state.modelTitle(action.model))")
                    let started = Date()
                    var first: TimeInterval?
                    do {
                        let answer = try await produce(action, text: text, direction: direction, streamToPopup: true) {
                            if first == nil { first = Date().timeIntervalSince(started) }
                        }
                        popup.showResult(answer.text, status: "Demo", stayUntilClicked: false)
                        print(String(format: "round %d first %.2fs total %.2fs complete=%@ model=%@ | %@", round,
                                     first ?? -1, Date().timeIntervalSince(started), answer.isComplete ? "yes" : "no",
                                     answer.model ?? "-", answer.text))
                    } catch {
                        popup.showError(error.localizedDescription)
                        print("round \(round) error: \(error.localizedDescription)")
                    }
                    fflush(stdout)
                    try? await Task.sleep(for: .seconds(5))
                }
                NSApp.terminate(nil)
            }
            return
        }
        state.refreshLoginItem()
        // `--demo-stream` streams a long text into the popup word by word and logs its frames.
        if arguments.contains("--demo-stream") {
            popup.demoFrameLog = true
            popup.beginAttempt()
            popup.showWorking(label: "Summarise · Sonnet")
            let words = String(repeating: "The popup should stay still while this answer streams in word by word, "
                + "growing only downwards without rewrapping or jumping. ", count: 12).split(separator: " ")
            Task { @MainActor [popup] in
                var text = ""
                for word in words {
                    try? await Task.sleep(for: .milliseconds(30))
                    text += (text.isEmpty ? "" : " ") + word
                    popup.update(text)
                }
                try? await Task.sleep(for: .milliseconds(100))
                popup.showResult(text, status: "Copied", stayUntilClicked: false)
            }
            return
        }
        if let problem = ActionStore.loadProblem {
            popup.showError(problem)
        }
        Log.write("launch accessibility=\(SelectionCopier.hasPermission) actions=\(state.file.actions.count) "
            + "unavailable=\(state.unavailableShortcuts.count)")
        if !SelectionCopier.hasPermission {
            SelectionCopier.requestPermission()
            waitForPermission()
        }
        if let translation = state.file.actions.first(where: \.isTranslation), translation.model != "apple",
           !CodexRunner.isCodex(translation.model) {
            claude.prewarm(model: translation.model, system: instruction(for: translation))
        }
        // One Codex process serves every action, so each Codex action gets a conversation started in advance.
        let codexActions = state.file.actions.filter { CodexRunner.isCodex($0.model) }
        for action in codexActions.prefix(3) {
            codex.prewarm(model: action.model, system: instruction(for: action))
        }
        if !codexActions.isEmpty { loadCodexModels() }
    }

    /// Records the moment the person turns the switch on, so it can be confirmed from the log.
    private func waitForPermission() {
        Task { @MainActor in
            while !SelectionCopier.hasPermission {
                try? await Task.sleep(for: .seconds(1))
            }
            Log.write("accessibility granted")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        claude.shutdown()
        codex.shutdown()
    }

    // MARK: Settings and shortcuts

    /// Applies popup settings and re-registers the shortcuts when any of them changed.
    private func applySettings() {
        popup.hideDelay = state.file.general.hideDelay
        popup.screenChoice = state.file.general.popupScreen
        popup.appearance = state.file.general.appearance
        claude.keepOnly(state.file.actions.filter { $0.model != "apple" && !CodexRunner.isCodex($0.model) }
            .map { ($0.model, instruction(for: $0)) })
        codex.keepOnly(state.file.actions.filter { CodexRunner.isCodex($0.model) }.map { ($0.model, instruction(for: $0)) })
        let wanted = state.file.actions.map(\.shortcut) + [state.file.general.listShortcut]
        guard wanted != registeredShortcuts || hotKeys.isEmpty else { return }
        releaseShortcuts()
        var unavailable: Set<String> = []
        for action in state.file.actions {
            guard let shortcut = Shortcut(action.shortcut) else { continue }
            let id = action.id
            if let hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, action: { [weak self] in
                MainActor.assumeIsolated { self?.run(actionID: id) }
            }) {
                hotKeys.append(hotKey)
            } else {
                unavailable.insert(id.uuidString)
            }
        }
        if let list = Shortcut(state.file.general.listShortcut) {
            if let hotKey = HotKey(keyCode: list.keyCode, modifiers: list.modifiers, action: { [weak self] in
                MainActor.assumeIsolated { self?.showActionList() }
            }) {
                hotKeys.append(hotKey)
            } else {
                unavailable.insert("list")
            }
        }
        registeredShortcuts = wanted
        state.unavailableShortcuts = unavailable
    }

    private func releaseShortcuts() {
        hotKeys.forEach { $0.invalidate() }
        hotKeys = []
        registeredShortcuts = []
    }

    // MARK: List of actions

    private func showActionList() {
        attempts += 1
        let attempt = attempts
        currentTask?.cancel()
        currentTask = Task { @MainActor in
            guard SelectionCopier.hasPermission else { return askForPermission() }
            popup.beginAttempt()
            let releaseKey = Shortcut(state.file.general.listShortcut)?.releaseKey ?? CGKeyCode(kVK_ANSI_0)
            let targetApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let outcome = await SelectionCopier.copySelection(attempt: attempt, releaseKey: releaseKey, targetApp: targetApp)
            guard let text = copiedText(outcome) else { return }
            let actions = state.file.actions
            let items = actions.enumerated().map { index, action in
                ListItem(id: index, name: action.name, detail: state.modelTitle(action.model),
                         shortcut: action.shortcut.isEmpty ? "" : Shortcut.display(action.shortcut))
            }
            popup.showList(items) { [weak self] index in
                guard let self, let index, actions.indices.contains(index) else { return }
                Log.write("#\(attempt) picked from list: \(actions[index].name)")
                self.run(actionID: actions[index].id, text: text)
            }
        }
    }

    // MARK: Running an action

    /// Runs an action on the selection. `text` is given when the selection was already copied, from the list.
    private func run(actionID: UUID, text preCopied: String? = nil) {
        guard let action = state.file.actions.first(where: { $0.id == actionID }) else { return }
        attempts += 1
        let attempt = attempts
        currentTask?.cancel()
        currentTask = Task { @MainActor in
            guard SelectionCopier.hasPermission else { return askForPermission() }
            popup.beginAttempt()
            let started = Date()
            let targetApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let text: String
            if let preCopied {
                text = preCopied
            } else {
                let releaseKey = Shortcut(action.shortcut)?.releaseKey ?? CGKeyCode(kVK_ANSI_C)
                let outcome = await SelectionCopier.copySelection(attempt: attempt, releaseKey: releaseKey, targetApp: targetApp)
                guard let copied = copiedText(outcome) else { return }
                text = copied
            }

            let direction = action.isTranslation ? Direction.detect(text) : nil
            let label = direction.map { "\(state.modelTitle(action.model)) · \($0.label)" }
                ?? "\(action.name) · \(state.modelTitle(action.model))"
            let showsPopup = action.popup != .hidden
            if showsPopup { popup.showWorking(label: label) }
            do {
                let answer = try await produce(action, text: text, direction: direction, streamToPopup: showsPopup)
                try Task.checkCancellation()
                guard answer.isComplete else {
                    let limit = action.isTranslation ? "30 seconds" : "3 minutes"
                    popup.showIncomplete(answer.text, label: label,
                                         notice: "\(CodexRunner.isCodex(action.model) ? "Codex" : "Claude") didn't finish within \(limit), so nothing was copied or pasted. "
                                            + "This is the part it wrote:")
                    Log.write("#\(attempt) action=\(action.name) unfinished after \(limit) characters=\(answer.text.count)")
                    return
                }
                let result = answer.text
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
                state.lastResult = (label: label, text: result)

                var status = "Copied"
                if action.result == .replace {
                    try? await Task.sleep(for: .milliseconds(60))
                    // Paste only if this is still the latest press, the text came from the application in front,
                    // and the clipboard still holds this result; otherwise it stays copied only.
                    if Task.isCancelled { return }
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp,
                       NSPasteboard.general.string(forType: .string) == result {
                        SelectionCopier.paste()
                        status = "Replaced"
                    } else {
                        status = "Copied · app changed, not pasted"
                    }
                }
                if showsPopup {
                    popup.showResult(result, status: status, stayUntilClicked: action.popup == .stay)
                }
                Log.write("#\(attempt) action=\(action.name) model=\(action.model) resolved=\(state.resolvedModels[action.model] ?? "-") "
                    + "result=\(action.result.rawValue) popup=\(action.popup.rawValue) status=\(status) "
                    + "totalMs=\(Int(Date().timeIntervalSince(started) * 1000)) characters=\(result.count)")
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                Log.write("#\(attempt) action=\(action.name) error=\(error.localizedDescription.prefix(200))")
                popup.showError(error.localizedDescription, label: label)
            }
        }
    }

    private func produce(_ action: ActionConfig, text: String, direction: Direction?,
                         streamToPopup: Bool, onFirstText: @escaping @MainActor () -> Void = {}) async throws -> ModelAnswer {
        if action.model == "apple" {
            guard let direction else {
                throw TranslationFailure(message: "Apple Translation can only translate. Choose a Claude or Codex model for \"\(action.name)\".")
            }
            return ModelAnswer(text: try await apple.translate(text, direction: direction), model: nil, isComplete: true)
        }
        let system = instruction(for: action)
        let message = direction.map { "Translate into \($0.targetName):\n<text>\(text)</text>" } ?? "<text>\(text)</text>"
        let timeout: Duration = action.isTranslation ? .seconds(30) : .seconds(180)
        let onPartial: @MainActor (String) -> Void = { [weak self] partial in
            onFirstText()
            if streamToPopup { self?.popup.update(partial) }
        }
        let answer = CodexRunner.isCodex(action.model)
            ? try await codex.run(model: action.model, system: system, message: message, timeout: timeout,
                                  onPartial: onPartial)
            : try await claude.run(model: action.model, system: system, message: message, timeout: timeout,
                                   onPartial: onPartial)
        if let model = answer.model, state.resolvedModels[action.model] != model {
            state.resolvedModels[action.model] = model
        }
        return answer
    }

    /// Asks the installed Codex which models the account can use, for the model pickers in the settings.
    private func loadCodexModels() {
        guard codex.isInstalled else { return }
        Task {
            do {
                let models = try await codex.listModels()
                state.codexModels = models.map(\.model)
            } catch {
                Log.write("codex models not loaded: \(error.localizedDescription.prefix(200))")
            }
            // The list starts Codex; stop it again if no action uses it.
            applySettings()
        }
    }

    private func instruction(for action: ActionConfig) -> String {
        let prompt = action.isTranslation && action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ClaudeRunner.translationPrompt : action.prompt
        return prompt.replacingOccurrences(of: "{your language}", with: Direction.name(Direction.home))
    }

    /// Turns the outcome of a copy into text, reporting the cases where there is none.
    private func copiedText(_ outcome: CopyOutcome) -> String? {
        switch outcome {
        case .text(let text):
            return text
        case .nothingSelected:
            popup.showError("No text selected.")
        case .applicationChanged:
            popup.showError("Another app came to the front, so nothing was copied. Try again.")
        case .cancelled:
            break // A newer press of a shortcut replaced this one; it reports its own result.
        }
        return nil
    }

    private func askForPermission() {
        SelectionCopier.requestPermission()
        popup.showError("Allow QuickPrompt in System Settings → Privacy & Security → Accessibility, then try again.")
    }

    // MARK: Menu bar popover and settings window

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "QuickPrompt")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        popover.animates = true
        let content = NSHostingController(rootView: MenuPopoverView(
            openSettings: { [weak self] id in self?.openSettings(id) },
            showLastResult: { [weak self] in self?.showLastResult() },
            quit: { NSApp.terminate(nil) }
        ).environmentObject(state))
        // Without this the panel keeps the size it first measured, and larger text overflows it upwards.
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Shows a sample result, so the appearance settings can be judged without running an action.
    private func showPreview() {
        popup.beginAttempt()
        popup.reopen("""
            This is how a result looks with the current settings. The text size, the padding on each side, the space \
            between lines and the maximum width all apply here.
            Это пример результата: размер текста, отступы с каждой стороны, межстрочный интервал и ширина плашки.
            """, label: "Preview · Sonnet")
    }

    private func showLastResult() {
        popover.performClose(nil)
        if let last = state.lastResult { popup.reopen(last.text, label: last.label) }
    }

    private func openSettings(_ actionID: UUID?) {
        popover.performClose(nil)
        if let actionID { state.selectedActionID = actionID }
        if state.codexModels.isEmpty { loadCodexModels() }
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environmentObject(state)))
            window.title = "QuickPrompt Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 820, height: 580))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
