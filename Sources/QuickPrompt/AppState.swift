import AppKit
import Combine
import ServiceManagement

/// The single source of truth for actions and settings. Every change is saved to the actions file
/// and re-registers the shortcuts, so the settings window, the menu and the shortcuts never disagree.
@MainActor
final class AppState: ObservableObject {
    @Published var file: ActionsFile {
        didSet {
            guard file != oldValue else { return }
            ActionStore.save(file)
            if !isRecordingShortcut { onShortcutsChanged() }
        }
    }
    /// The full model name each alias resolved to last time, for example "sonnet" → "claude-sonnet-5".
    @Published var resolvedModels: [String: String] {
        didSet { UserDefaults.standard.set(resolvedModels, forKey: "resolvedModels") }
    }
    /// Shortcuts that macOS refused because another application holds them, by action identifier
    /// (or "list" for the list shortcut).
    @Published var unavailableShortcuts: Set<String> = []
    @Published var lastResult: (label: String, text: String)?
    /// Selected action in the settings window.
    @Published var selectedActionID: UUID?

    /// While the recorder listens for a new shortcut, the global shortcuts are released so that pressing
    /// an existing combination records it instead of running an action.
    @Published var isRecordingShortcut = false {
        didSet {
            guard isRecordingShortcut != oldValue else { return }
            isRecordingShortcut ? onRecordingStarted() : onShortcutsChanged()
        }
    }

    var onShortcutsChanged: () -> Void = {}
    var onRecordingStarted: () -> Void = {}
    var onPreview: () -> Void = {}

    /// Codex models the signed-in account can use, as "codex:<id>"; empty when Codex is not installed.
    @Published var codexModels: [String] = []

    init() {
        file = ActionStore.load()
        resolvedModels = UserDefaults.standard.dictionary(forKey: "resolvedModels") as? [String: String] ?? [:]
    }

    // MARK: Editing actions

    func addAction() {
        let action = ActionConfig(name: "New action", shortcut: "", model: "sonnet", prompt: ActionStore.newActionPrompt,
                                  result: .copy, popup: .stay, isTranslation: false)
        file.actions.append(action)
        selectedActionID = action.id
    }

    /// Translate is the only action that detects the language, so it is never copied.
    func canDuplicate(_ id: UUID) -> Bool {
        file.actions.contains { $0.id == id && !$0.isTranslation }
    }

    func duplicate(_ id: UUID) {
        guard canDuplicate(id), let index = file.actions.firstIndex(where: { $0.id == id }) else { return }
        var copy = file.actions[index]
        copy.id = UUID()
        copy.name += " copy"
        copy.shortcut = ""
        file.actions.insert(copy, at: index + 1)
        selectedActionID = copy.id
    }

    /// Every action can be deleted except Translate, which the app is built around.
    func canDelete(_ id: UUID) -> Bool {
        file.actions.contains { $0.id == id && !$0.isTranslation }
    }

    func delete(_ id: UUID) {
        guard canDelete(id), let index = file.actions.firstIndex(where: { $0.id == id }) else { return }
        file.actions.remove(at: index)
        selectedActionID = file.actions.indices.contains(index) ? file.actions[index].id : file.actions.last?.id
    }

    func move(from source: IndexSet, to destination: Int) {
        file.actions.move(fromOffsets: source, toOffset: destination)
    }

    /// The other action or the list shortcut already using this shortcut, if any.
    func conflict(for shortcut: String, excluding id: UUID?) -> String? {
        guard let wanted = Shortcut(shortcut) else { return nil }
        if id != nil, Shortcut(file.general.listShortcut) == wanted { return "the list of actions" }
        return file.actions.first { $0.id != id && Shortcut($0.shortcut) == wanted }?.name
    }

    // MARK: Models

    func modelTitle(_ model: String) -> String {
        if model == "apple" { return "Apple Translation" }
        if CodexRunner.isCodex(model) { return "Codex " + CodexRunner.shortName(model) }
        return model.prefix(1).uppercased() + model.dropFirst()
    }

    func modelDetail(_ model: String) -> String? {
        model == "apple" ? "on this Mac" : CodexRunner.isCodex(model) ? nil : resolvedModels[model]
    }

    // MARK: Launch at login

    private static let loginItemPathKey = "loginItemPath"

    /// A login item remembers where the app was. After the app moves or is renamed (QuickTranslate.app became
    /// QuickPrompt.app), it still counts as enabled but starts nothing at login. Registering again points it at the
    /// app's current place.
    func refreshLoginItem() {
        guard SMAppService.mainApp.status == .enabled else { return }
        let path = Bundle.main.bundlePath
        guard UserDefaults.standard.string(forKey: Self.loginItemPathKey) != path else { return }
        do {
            try SMAppService.mainApp.unregister()
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(path, forKey: Self.loginItemPathKey)
            Log.write("login item registered again for \(path)")
        } catch {
            Log.write("login item refresh failed: \(error.localizedDescription)")
        }
    }

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                UserDefaults.standard.set(newValue ? Bundle.main.bundlePath : nil, forKey: Self.loginItemPathKey)
            } catch {
                Log.write("launch at login change failed: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }
}
