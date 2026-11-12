import AppKit
import SwiftUI

enum SettingsPage: Hashable {
    case action(UUID)
    case general
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var page: SettingsPage?
    @State private var pendingDeletion: ActionConfig?

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section("Actions") {
                    ForEach(state.file.actions) { action in
                        HStack(spacing: 8) {
                            Image(systemName: action.icon).frame(width: 16).foregroundStyle(.secondary)
                            Text(action.name).lineLimit(1)
                            Spacer()
                            Text(Shortcut.display(action.shortcut))
                                .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                        }
                        .tag(SettingsPage.action(action.id))
                    }
                    .onMove { state.move(from: $0, to: $1) }
                }
                Section("App") {
                    Label("General", systemImage: "gearshape").tag(SettingsPage.general)
                }
            }
            .safeAreaInset(edge: .bottom) { actionButtons }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            switch page {
            case .action(let id):
                if let binding = binding(for: id) {
                    ActionEditor(action: binding).id(id)
                } else {
                    placeholder
                }
            case .general:
                GeneralEditor()
            case nil:
                placeholder
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .onAppear { page = state.selectedActionID.map(SettingsPage.action) ?? state.file.actions.first.map { .action($0.id) } }
        .onChange(of: state.selectedActionID) { _, id in
            if let id { page = .action(id) }
        }
        .onChange(of: page) { _, page in
            if case .action(let id) = page { state.selectedActionID = id }
        }
        .alert("Delete “\(pendingDeletion?.name ?? "")”?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Delete", role: .destructive) {
                if let action = pendingDeletion { state.delete(action.id) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Its shortcut and instruction will be removed. This can't be undone.")
        }
    }

    private var canDeleteSelection: Bool {
        if case .action(let id) = page { return state.canDelete(id) }
        return false
    }

    private var canDuplicateSelection: Bool {
        if case .action(let id) = page { return state.canDuplicate(id) }
        return false
    }

    private var placeholder: some View {
        Text("Choose an action on the left").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            Button { state.addAction() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                .help("Add action")
            Button {
                if case .action(let id) = page { pendingDeletion = state.file.actions.first { $0.id == id } }
            } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                .disabled(!canDeleteSelection)
                .help(canDeleteSelection ? "Delete action" : "Translate can't be deleted")
            Button {
                if case .action(let id) = page { state.duplicate(id) }
            } label: { Image(systemName: "plus.square.on.square").frame(width: 24, height: 20) }
                .disabled(!canDuplicateSelection)
                .help(canDuplicateSelection ? "Duplicate action" : "Translate can't be duplicated")
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    private func binding(for id: UUID) -> Binding<ActionConfig>? {
        guard state.file.actions.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { state.file.actions.first(where: { $0.id == id }) ?? state.file.actions[0] },
            set: { newValue in
                if let index = state.file.actions.firstIndex(where: { $0.id == id }) {
                    state.file.actions[index] = newValue
                }
            })
    }
}

// MARK: - Action editor

struct ActionEditor: View {
    @EnvironmentObject var state: AppState
    @Binding var action: ActionConfig

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $action.name)
                LabeledContent("Shortcut") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ShortcutRecorder(shortcut: $action.shortcut)
                        if let other = state.conflict(for: action.shortcut, excluding: action.id) {
                            Text("Also used by \(other)").font(.caption).foregroundStyle(.orange)
                        } else if state.unavailableShortcuts.contains(action.id.uuidString) {
                            Text("Taken by another app. Choose a different one.").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Picker("Model", selection: $action.model) {
                    if action.isTranslation {
                        Section("Apple") { modelRow("apple") }
                    }
                    Section("Claude") {
                        ForEach(claudeModels, id: \.self) { modelRow($0) }
                    }
                    if !codexModels.isEmpty {
                        Section("Codex") {
                            ForEach(codexModels, id: \.self) { modelRow($0) }
                        }
                    }
                }
            }
            Section {
                Picker("Result", selection: $action.result) {
                    ForEach(ResultMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Popup", selection: $action.popup) {
                    ForEach(PopupMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(resultHint).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: $action.prompt)
                    .font(.system(size: 13))
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .disabled(action.model == "apple")
                    .opacity(action.model == "apple" ? 0.45 : 1)
            } header: {
                Text("Instruction")
            } footer: {
                if action.model == "apple" {
                    Text("Apple Translation does not use an instruction. Choose a Claude or Codex model to use it.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if action.isTranslation {
                    Text("The app adds \"Translate into …\" with the detected direction to every request.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(action.name)
    }

    /// Apple Translation (for Translate only), the Claude Code aliases, then the Codex models, plus the action's
    /// current model if it is no longer offered.
    /// The Claude Code aliases, plus the action's current Claude model if it is no longer offered.
    private var claudeModels: [String] {
        let current = action.model != "apple" && !CodexRunner.isCodex(action.model)
            && !state.file.models.contains(action.model)
        return state.file.models + (current ? [action.model] : [])
    }

    /// The models the installed Codex offers, plus the action's current Codex model if it is no longer offered.
    private var codexModels: [String] {
        let current = CodexRunner.isCodex(action.model) && !state.codexModels.contains(action.model)
        return state.codexModels + (current ? [action.model] : [])
    }

    /// Inside a group the engine is not repeated: "Sonnet", "6.1 Sol".
    @ViewBuilder private func modelRow(_ model: String) -> some View {
        let name = CodexRunner.isCodex(model) ? CodexRunner.shortName(model) : state.modelTitle(model)
        if let detail = state.modelDetail(model) {
            Text("\(name)  ·  \(detail)").tag(model)
        } else {
            Text(name).tag(model)
        }
    }

    private var resultHint: String {
        let result = action.result == .replace
            ? "The result is pasted over the selected text and is also on the clipboard."
            : "The result goes to the clipboard."
        let popup: String
        switch action.popup {
        case .autoHide: popup = "The popup hides after \(Int(state.file.general.hideDelay)) s, or stays while the pointer is over it."
        case .stay: popup = "The popup stays until you click it."
        case .compact: popup = "Only a small status beside the notch while it runs; it closes when done. Click it to see the text; errors open the full popup."
        case .hidden: popup = "No popup, except for errors."
        }
        return result + " " + popup
    }
}

// MARK: - General settings

struct GeneralEditor: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                LabeledContent("List of all actions") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ShortcutRecorder(shortcut: $state.file.general.listShortcut)
                        if let other = state.conflict(for: state.file.general.listShortcut, excluding: nil) {
                            Text("Also used by \(other)").font(.caption).foregroundStyle(.orange)
                        } else if state.unavailableShortcuts.contains("list") {
                            Text("Taken by another app. Choose a different one.").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            } footer: {
                Text("Select text, press this shortcut, then pick an action with a digit, the arrow keys and Return, or a click.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Popup") {
                LabeledContent("Hide after") {
                    Stepper("\(Int(state.file.general.hideDelay)) s", value: $state.file.general.hideDelay, in: 1...20, step: 1)
                }
                Picker("Show on", selection: $state.file.general.popupScreen) {
                    ForEach(PopupScreen.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                AppearanceSlider(title: "Result text size", value: $state.file.general.appearance.resultFontSize,
                                 range: Appearance.ranges["resultFontSize"]!, unit: "pt")
                AppearanceSlider(title: "Menu and list text size", value: $state.file.general.appearance.menuFontSize,
                                 range: Appearance.ranges["menuFontSize"]!, unit: "pt")
                AppearanceSlider(title: "Padding left", value: $state.file.general.appearance.paddingLeft,
                                 range: Appearance.ranges["padding"]!, unit: "pt")
                AppearanceSlider(title: "Padding right", value: $state.file.general.appearance.paddingRight,
                                 range: Appearance.ranges["padding"]!, unit: "pt")
                AppearanceSlider(title: "Padding top", value: $state.file.general.appearance.paddingTop,
                                 range: Appearance.ranges["padding"]!, unit: "pt")
                AppearanceSlider(title: "Padding bottom", value: $state.file.general.appearance.paddingBottom,
                                 range: Appearance.ranges["padding"]!, unit: "pt")
                AppearanceSlider(title: "Line spacing", value: $state.file.general.appearance.lineSpacing,
                                 range: Appearance.ranges["lineSpacing"]!, unit: "pt")
                AppearanceSlider(title: "Maximum width", value: $state.file.general.appearance.maximumWidth,
                                 range: Appearance.ranges["maximumWidth"]!, unit: "pt", step: 10)
                HStack {
                    Button("Show preview") { state.onPreview() }
                    Spacer()
                    Button("Reset to defaults") { state.file.general.appearance = Appearance() }
                }
            } header: {
                Text("Popup appearance")
            } footer: {
                Text("Result text size, padding, line spacing and width apply to the popup under the notch. "
                    + "Menu and list text size applies to this app's menu and to the list of all actions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Start with the Mac", isOn: Binding(get: { state.launchesAtLogin },
                                                           set: { state.launchesAtLogin = $0 }))
            }
            Section {
                LabeledContent("Actions file") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ActionStore.url]) }
                }
            } footer: {
                Text("Claude choices are Claude Code aliases, each meaning the latest model of its kind. Codex choices are "
                    + "the models your installed Codex offers to your account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

// MARK: - Appearance slider

struct AppearanceSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    var step: Double = 1

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step).frame(width: 200)
                Text("\(Int(value)) \(unit)").monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            }
        }
    }
}

// MARK: - Shortcut recorder

/// Click, then press the keys. Escape cancels, Delete clears.
struct ShortcutRecorder: View {
    @EnvironmentObject var state: AppState
    @Binding var shortcut: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Text(recording ? "Press keys…" : Shortcut.display(shortcut))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if recording {
                Text(hint ?? "Esc cancels · ⌫ clears").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
        // Leaving the window or the app while recording would leave every shortcut released; stop instead.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        hint = nil
        state.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: // Escape
                stop()
            case 51, 117: // Delete, Forward Delete
                shortcut = ""
                stop()
            default:
                if let recorded = Shortcut(event: event) {
                    shortcut = recorded.text
                    stop()
                } else {
                    hint = "Add ⌘, ⌥ or ⌃"
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            state.isRecordingShortcut = false
        }
    }
}
