import SwiftUI

/// The window that opens from the menu bar icon: the actions with their shortcuts, and the app commands.
/// Font sizes in the menu panel follow the "menu and list text size" setting; 13 pt is the design size.
private extension AppState {
    func menuFont(_ designSize: CGFloat) -> CGFloat {
        designSize * file.general.appearance.menuFontSize / 13
    }
}

struct MenuPopoverView: View {
    @EnvironmentObject var state: AppState
    var openSettings: (UUID?) -> Void
    var showLastResult: () -> Void
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "character.bubble.fill").font(.system(size: state.menuFont(18))).foregroundStyle(.tint)
                Text("QuickPrompt").font(.system(size: state.menuFont(14), weight: .semibold))
                Spacer()
                Circle().fill(SelectionCopier.hasPermission ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(SelectionCopier.hasPermission ? "Ready" : "Needs access")
                    .font(.system(size: state.menuFont(11))).foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                ForEach(state.file.actions) { action in
                    ActionCard(action: action) { openSettings(action.id) }
                }
            }

            HStack {
                Image(systemName: "list.bullet").foregroundStyle(.secondary)
                Text("All actions").font(.system(size: state.menuFont(12))).foregroundStyle(.secondary)
                Spacer()
                KeyCap(text: Shortcut.display(state.file.general.listShortcut))
            }
            .padding(.horizontal, 10)

            Divider()

            HStack(spacing: 4) {
                FooterButton(title: "Settings…", icon: "gearshape") { openSettings(nil) }
                FooterButton(title: "Last result", icon: "clock.arrow.circlepath", action: showLastResult)
                    .disabled(state.lastResult == nil)
                Spacer()
                FooterButton(title: "Quit", icon: "power", action: quit)
            }
        }
        .padding(14)
        .frame(width: state.menuFont(340))
    }
}

private struct ActionCard: View {
    @EnvironmentObject var state: AppState
    let action: ActionConfig
    let edit: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: edit) {
            HStack(spacing: 10) {
                Image(systemName: action.icon)
                    .font(.system(size: state.menuFont(14)))
                    .frame(width: state.menuFont(28), height: state.menuFont(28))
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.name).font(.system(size: state.menuFont(13), weight: .medium)).foregroundStyle(.primary)
                    Text(summary).font(.system(size: state.menuFont(11))).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                KeyCap(text: Shortcut.display(action.shortcut))
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.08 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Edit \(action.name)")
    }

    private var summary: String {
        let popup: String
        switch action.popup {
        case .autoHide: popup = "auto-hide"
        case .stay: popup = "stays until clicked"
        case .compact: popup = "compact"
        case .hidden: popup = "no popup"
        }
        return "\(state.modelTitle(action.model)) · \(action.result == .replace ? "replace" : "copy") · \(popup)"
    }
}

struct KeyCap: View {
    @EnvironmentObject var state: AppState
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: state.menuFont(11), weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.18)))
    }
}

private struct FooterButton: View {
    @EnvironmentObject var state: AppState
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: state.menuFont(12)))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
    }
}
