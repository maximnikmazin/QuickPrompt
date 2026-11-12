import AppKit
import SwiftUI

struct ListItem: Identifiable {
    let id: Int
    let name: String
    let detail: String
    let shortcut: String
}

final class PopupModel: ObservableObject {
    enum Phase { case working, done, error }
    enum Mode { case message, list }

    @Published var mode: Mode = .message
    @Published var label = ""
    @Published var text = ""
    @Published var phase: Phase = .working
    @Published var topInset: CGFloat = 0
    @Published var contentWidth: CGFloat = 400
    @Published var bodyHeight: CGFloat = 20
    @Published var scrolls = false
    /// Shown in green once the action has finished, for example "Copied" or "Replaced".
    @Published var status = "Copied"
    @Published var items: [ListItem] = []
    @Published var highlighted = 0
    @Published var appearance = Appearance()
    /// A short explanation above the text, in orange, for example when an answer was cut off.
    @Published var notice: String?
    @Published var noticeHeight: CGFloat = 0
    /// The "Compact" popup: only `compactLabel` left of the notch and the moving dots right of it, while it works.
    @Published var compact = false
    @Published var compactLabel = ""
    /// The width of each side next to the notch, the notch's own width, and the corner radii of the small shape.
    @Published var compactSide: CGFloat = 40
    @Published var compactGap: CGFloat = 200
    @Published var compactTopRadius: CGFloat = 0
    @Published var compactBottomRadius: CGFloat = 10
    /// The compact popup opens by widening the notch to both sides and closes by narrowing back to `compactClosedWidth`
    /// (the notch's width), with no fade.
    @Published var compactOpen = false
    /// The name and the dots: they come in while the notch widens and leave before it narrows.
    @Published var compactShown = false
    @Published var compactClosedWidth: CGFloat = 200
    var onPick: (Int) -> Void = { _ in }
    var onCancel: () -> Void = {}
}

/// The scroll mark of a long result: a faint track the height of the visible text, with a brighter part that shows
/// which piece of the text is on screen.
struct ScrollMark: View {
    let geometry: ScrollGeometry?

    var body: some View {
        GeometryReader { box in
            if let geometry, geometry.contentSize.height > geometry.containerSize.height + 1 {
                let track = box.size.height
                let content = geometry.contentSize.height
                let visible = geometry.containerSize.height
                let thumb = max(24, track * visible / content)
                let progress = min(1, max(0, geometry.contentOffset.y / (content - visible)))
                ZStack(alignment: .top) {
                    Capsule().fill(.white.opacity(0.055))
                    Capsule().fill(.white.opacity(0.22))
                        .frame(height: thumb)
                        .offset(y: (track - thumb) * progress)
                }
                .frame(width: 2)
            }
        }
        .frame(width: 2)
        .allowsHitTesting(false)
    }
}

/// Three white dots that brighten and rise one after another, like a typing indicator, as tall as one line of text.
struct LoadingDots: View {
    let size: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.32) {
                ForEach(0..<3) { index in
                    dot(wave: Self.wave(time: time, index: index))
                }
            }
            .frame(height: size * 1.25)
        }
    }

    /// 0…1: each dot follows the same smooth wave, a little after the previous one; one cycle takes 1.2 s.
    private static func wave(time: Double, index: Int) -> Double {
        let angle = time * 2 * Double.pi / 1.2 - Double(index) * 1.25
        return (sin(angle) + 1) / 2
    }

    private func dot(wave: Double) -> some View {
        let diameter = size * 0.42
        return Circle()
            .fill(Color.white)
            .frame(width: diameter, height: diameter)
            .opacity(0.25 + 0.65 * wave)
            .scaleEffect(0.8 + 0.25 * wave)
            .offset(y: -size * 0.12 * wave)
    }
}

struct PopupView: View {
    @ObservedObject var model: PopupModel
    @State private var scroll: ScrollGeometry?

    var body: some View {
        if model.compact && model.mode == .message {
            compactView
        } else {
            fullView
        }
    }

    /// The "Compact" popup: the action name on the left of the notch, the moving dots on the right, as tall as the
    /// notch. A click on it opens the full popup (NotchPopup.clicked).
    private var compactView: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: model.compactTopRadius,
                                           bottomLeadingRadius: model.compactBottomRadius,
                                           bottomTrailingRadius: model.compactBottomRadius,
                                           topTrailingRadius: model.compactTopRadius)
        return GeometryReader { box in
            ZStack {
                shape.fill(.black)
                compactContent.frame(width: box.size.width)
            }
            // The black shape grows out of the notch to both sides. The name and the dots come in while it widens
            // and leave before it narrows, so its edges never cut them.
            .frame(width: model.compactOpen ? box.size.width : model.compactClosedWidth, height: box.size.height)
            .clipShape(shape)
            .frame(width: box.size.width, height: box.size.height)
        }
        .contentShape(Rectangle())
    }

    private var compactContent: some View {
        HStack(spacing: 0) {
            Text(model.compactLabel)
                .font(.system(size: NotchPopup.compactFontSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: model.compactSide, alignment: .leading)
                .opacity(model.compactShown ? 1 : 0)
                .offset(x: model.compactShown ? 0 : 10)
            Color.clear.frame(width: model.compactGap)
            LoadingDots(size: NotchPopup.compactFontSize)
                .frame(width: model.compactSide, alignment: .trailing)
                .opacity(model.compactShown ? 1 : 0)
                .offset(x: model.compactShown ? 0 : -10)
        }
        .padding(.horizontal, NotchPopup.compactPadding)
    }

    private var fullView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(model.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 8)
                if model.mode == .list {
                    Text("1–9 · ↑↓ ↩ · esc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                } else if model.phase == .done {
                    Text(model.status)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.notice == nil ? Color.green.opacity(0.85) : Color.orange)
                }
                // A click on the cross closes the popup, as does a click anywhere else on a message.
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.white.opacity(0.12)))
            }
            if let notice = model.notice, model.mode == .message {
                Text(notice)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: model.noticeHeight, alignment: .topLeading)
            }
            if model.mode == .list {
                list
            } else if model.scrolls {
                ScrollViewReader { reader in
                    ScrollView(.vertical) {
                        bodyText
                        Color.clear.frame(height: 1).id("end")
                    }
                    .scrollIndicators(.never)
                    .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
                        scroll = geometry
                    }
                    .overlay(alignment: .topTrailing) {
                        // A thin, faint bar in the right margin: it tells that the text goes on below or above.
                        ScrollMark(geometry: scroll)
                            // 8 pt from the popup's right edge, whatever the right padding is.
                            .offset(x: max(0, model.appearance.paddingRight - 10))
                    }
                    .onChange(of: model.text) { _, _ in
                        if model.phase == .working { reader.scrollTo("end", anchor: .bottom) }
                    }
                    .onChange(of: model.phase) { _, phase in
                        if phase != .working { reader.scrollTo("start", anchor: .top) }
                    }
                    .onAppear { if model.phase == .working { reader.scrollTo("end", anchor: .bottom) } }
                }
                .frame(height: model.bodyHeight)
            } else {
                bodyText.frame(height: model.bodyHeight, alignment: .top)
            }
        }
        .padding(.top, model.topInset + model.appearance.paddingTop)
        .padding(.leading, model.appearance.paddingLeft)
        .padding(.trailing, model.appearance.paddingRight)
        .padding(.bottom, model.appearance.paddingBottom)
        .frame(width: model.contentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22).fill(.black))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
        .contentShape(Rectangle())
        // In the list, the rows pick an action; a click anywhere else, including the cross, closes it.
        .onTapGesture { if model.mode == .list { model.onCancel() } }
    }

    private var list: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) { listRows }
                .scrollIndicators(.automatic)
                .onChange(of: model.highlighted) { _, row in reader.scrollTo(row) }
        }
        .frame(height: model.bodyHeight, alignment: .top)
    }

    private var listRows: some View {
        VStack(spacing: 2) {
            ForEach(model.items) { item in
                HStack(spacing: 10) {
                    Text(item.id < 9 ? "\(item.id + 1)" : "")
                        .font(.system(size: menuSize - 2, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: menuSize + 7, height: menuSize + 7)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.12)))
                    Text(item.name).font(.system(size: menuSize, weight: .medium)).foregroundStyle(.white)
                    Text(item.detail).font(.system(size: menuSize - 2)).foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Text(item.shortcut).font(.system(size: menuSize - 2, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 8)
                .frame(height: NotchPopup.rowHeight(menuSize) - 2)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(item.id == model.highlighted ? 0.14 : 0)))
                .contentShape(Rectangle())
                .onTapGesture { model.onPick(item.id) }
                .onHover { if $0 { model.highlighted = item.id } }
                .id(item.id)
            }
        }
    }

    private var menuSize: CGFloat { model.appearance.menuFontSize }

    @ViewBuilder private var bodyText: some View {
        if model.text.isEmpty && model.phase == .working {
            // While waiting for the first words: three dots in a slow wave, in place of the text.
            LoadingDots(size: model.appearance.resultFontSize)
                .id("start")
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            resultText
        }
    }

    @ViewBuilder private var resultText: some View {
        if model.phase == .error || model.text.isEmpty {
            Text(model.text.isEmpty ? "Working…" : model.text)
                .id("start")
                .font(.system(size: model.appearance.resultFontSize))
                .lineSpacing(model.appearance.lineSpacing)
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // Models answer in Markdown; it is shown as formatting, not as ** and - marks.
            MarkdownBody(text: model.text, fontSize: model.appearance.resultFontSize,
                         lineSpacing: model.appearance.lineSpacing, color: textColor)
                .id("start")
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var textColor: Color {
        switch model.phase {
        case .working: return model.text.isEmpty ? .white.opacity(0.5) : .white.opacity(0.85)
        case .done: return .white
        case .error: return Color(red: 1, green: 0.6, blue: 0.55)
        }
    }
}

/// A borderless panel that may sit over the menu bar and never takes focus from the person's app,
/// except while the list of actions waits for a key.
final class IslandPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    var acceptsKeys = false
    override var canBecomeKey: Bool { acceptsKeys }
    override var canBecomeMain: Bool { false }

    var onClick: () -> Void = {}

    /// Any click on a message closes it, wherever it lands. In the list, clicks pick an action.
    override func sendEvent(_ event: NSEvent) {
        if !acceptsKeys, event.type == .leftMouseDown || event.type == .rightMouseDown {
            onClick()
            return
        }
        super.sendEvent(event)
    }
}

/// Reports when the pointer enters or leaves, even though the panel is never active.
final class HoverView: NSView {
    var onHover: (Bool) -> Void = { _ in }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

/// The popup that grows out of the notch, like the Dynamic Island.
@MainActor
final class NotchPopup {
    static func rowHeight(_ menuFontSize: CGFloat) -> CGFloat { menuFontSize + 19 }
    static let compactFontSize: CGFloat = 11
    static let compactPadding: CGFloat = 12

    var appearance = Appearance() {
        didSet {
            guard appearance != oldValue else { return }
            model.appearance = appearance
            // Resize a visible popup at once, so the preview follows the sliders.
            if visible { layout() }
        }
    }

    var hideDelay: TimeInterval = 4
    /// Development only: log every popup frame, used by `--demo-stream`.
    var demoFrameLog = false
    var screenChoice: PopupScreen = .notch

    private let model = PopupModel()
    private let measurer = MarkdownMeasurer()
    private let panel: IslandPanel
    private let hoverView = HoverView()
    private var hideTimer: Timer?
    private var hovering = false
    private var visible = false
    /// Set when the person closes the popup; the running action then finishes without reopening it.
    private var dismissed = false
    private var stickUntilClicked = false
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?
    private var listCompletion: ((Int?) -> Void)?
    /// Esc closes a visible message. It is held only while a message is on screen.
    private var escapeKey: HotKey?
    /// Streaming updates are drawn at most every 50 ms; the full text is always kept.
    private var pendingPartial: String?
    private var partialFlushScheduled = false
    /// The text area height reached during the current stream; it never shrinks until the answer is complete.
    private var streamedBodyHeight: CGFloat = 0

    init() {
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let hosting = NSHostingView(rootView: PopupView(model: model))
        hosting.autoresizingMask = [.width, .height]
        hoverView.addSubview(hosting)
        hoverView.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        panel.onClick = { [weak self] in self?.clicked() }
        panel.contentView = hoverView
        model.onPick = { [weak self] index in self?.finishList(index) }
        model.onCancel = { [weak self] in self?.finishList(nil) }
    }

    /// Called at the start of every shortcut press, so that closing an earlier popup does not hide
    /// the messages of this one.
    func beginAttempt() {
        dismissed = false
        pendingPartial = nil
    }

    /// With `compactLabel` the popup is the "Compact" one: that name and the moving dots beside the notch, until the
    /// result comes (it then closes at once), an error comes, or the person clicks it.
    func showWorking(label: String, compactLabel: String? = nil) {
        endListMode()
        dismissed = false
        stickUntilClicked = false
        hideTimer?.invalidate()
        model.mode = .message
        model.compact = compactLabel != nil
        model.compactLabel = compactLabel ?? ""
        model.label = label
        model.notice = nil
        model.text = ""
        model.phase = .working
        streamedBodyHeight = 0
        layout()
    }

    func update(_ partial: String) {
        guard model.mode == .message, model.phase == .working, !dismissed else { return }
        pendingPartial = partial
        guard !partialFlushScheduled else { return }
        partialFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.partialFlushScheduled = false
                guard let text = self.pendingPartial, self.model.mode == .message, self.model.phase == .working,
                      !self.dismissed else { return }
                self.pendingPartial = nil
                self.model.text = text
                self.layout()
            }
        }
    }

    /// Shows the finished result. With `stayUntilClicked` the popup stays until the person clicks it,
    /// which suits results meant to be read, such as a summary.
    func showResult(_ text: String, label: String? = nil, status: String = "Copied", stayUntilClicked: Bool = false) {
        guard !dismissed else { return }
        pendingPartial = nil
        // The compact popup shows no result: it goes back into the notch as soon as the action is done.
        if model.compact, model.mode == .message {
            model.text = text
            model.phase = .done
            hideTimer?.invalidate()
            hide(evenWhileHovered: true)
            return
        }
        endListMode()
        model.mode = .message
        if let label { model.label = label }
        model.notice = nil
        model.text = text
        model.status = status
        model.phase = .done
        stickUntilClicked = stayUntilClicked
        layout()
        scheduleHide()
    }

    /// Shows a message again even after the person closed the previous one, for example "Last result".
    func reopen(_ text: String, label: String) {
        dismissed = false
        model.compact = false
        showResult(text, label: label, status: "Last result", stayUntilClicked: true)
    }

    /// Shows an answer that stopped before Claude finished. It is not copied; the popup stays until clicked.
    func showIncomplete(_ text: String, label: String, notice: String) {
        guard !dismissed else { return }
        model.compact = false
        showResult(text, label: label, status: "Unfinished · not copied", stayUntilClicked: true)
        model.notice = notice
        layout()
    }

    func showError(_ message: String, label: String = "QuickPrompt") {
        guard !dismissed else { return }
        pendingPartial = nil
        endListMode()
        model.mode = .message
        // An error always opens the full popup, also for a "Compact" action.
        model.compact = false
        model.label = label
        model.notice = nil
        model.text = message
        model.phase = .error
        layout()
        scheduleHide()
    }

    // MARK: List of actions

    /// Shows the actions and calls `completion` with the chosen index, or nil when the person cancels.
    func showList(_ items: [ListItem], completion: @escaping (Int?) -> Void) {
        hideTimer?.invalidate()
        dismissed = false
        stickUntilClicked = true
        listCompletion = completion
        model.compact = false
        model.mode = .list
        model.label = "Choose an action"
        model.items = items
        model.highlighted = 0
        layout()
        panel.acceptsKeys = true
        panel.makeKey()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishList(nil) }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.model.mode == .list else { return event }
            switch event.keyCode {
            case 53: self.finishList(nil) // Escape
            case 36, 76: self.finishList(self.model.highlighted) // Return, Enter
            case 125: self.model.highlighted = min(self.model.highlighted + 1, self.model.items.count - 1)
            case 126: self.model.highlighted = max(self.model.highlighted - 1, 0)
            default:
                if let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit),
                   digit <= self.model.items.count {
                    self.finishList(digit - 1)
                }
            }
            return nil
        }
    }

    private func finishList(_ index: Int?) {
        guard let completion = listCompletion else { return }
        listCompletion = nil
        endListMode()
        // Give the keyboard back to the person's application before the action copies or pastes.
        visible = false
        holdEscape(false)
        panel.orderOut(nil)
        completion(index)
    }

    private func endListMode() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        if panel.acceptsKeys {
            panel.acceptsKeys = false
            if listCompletion != nil { finishList(nil) }
        }
    }

    /// Renders the popup to a PNG and prints where it sits relative to the notch (demo mode only).
    func writeSnapshot(to path: String) {
        let screen = targetScreen()
        FileHandle.standardError.write(Data("screen \(screen.localizedName) frame \(screen.frame) notch \(Self.notchRect(on: screen)) popup \(panel.frame) visible \(panel.isVisible)\n".utf8))
        // The window itself is drawn into the image: SwiftUI's ImageRenderer leaves the formatted text out.
        guard let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: Hiding

    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        if inside {
            hideTimer?.invalidate()
        } else if model.mode == .message, model.phase != .working {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        guard !hovering, model.mode == .message, !(stickUntilClicked && model.phase == .done) else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: hideDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func holdEscape(_ hold: Bool) {
        if hold, escapeKey == nil {
            escapeKey = HotKey(keyCode: UInt32(53), modifiers: 0) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.model.mode == .list { self.finishList(nil) } else { self.dismiss() }
                }
            }
        } else if !hold {
            escapeKey?.invalidate()
            escapeKey = nil
        }
    }

    /// Development only: the same as a click on the popup, used by `--demo-compact … --click <seconds>`.
    func demoClick() { clicked() }

    /// A click on the compact popup while it works opens the full popup with the text as it streams in; any other
    /// click on a message closes it.
    private func clicked() {
        if model.compact, model.mode == .message, model.phase == .working {
            model.compact = false
            layout()
            return
        }
        dismiss()
    }

    private func dismiss() {
        dismissed = true
        hideTimer?.invalidate()
        hide(evenWhileHovered: true)
    }

    private func hide(evenWhileHovered: Bool = false) {
        guard visible, evenWhileHovered || !hovering else { return }
        visible = false
        hovering = false
        holdEscape(false)
        if model.compact, model.mode == .message {
            // The text leaves first, then the notch narrows back, empty; the window itself never fades.
            withAnimation(.easeIn(duration: Self.compactTextLeaving)) { model.compactShown = false }
            withAnimation(Self.compactClosing.delay(Self.compactNarrowDelay)) { model.compactOpen = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.compactNarrowDelay + 0.26) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.visible else { return }
                    self.panel.orderOut(nil)
                    self.model.compact = false
                }
            }
            return
        }
        let screen = targetScreen()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(Self.notchRect(on: screen), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.visible else { return }
                self.panel.orderOut(nil)
                self.model.compact = false
            }
        })
    }

    // MARK: Geometry

    private func layout() {
        if model.mode == .message && model.compact {
            presentCompact(compactFrame())
            return
        }
        let streaming = model.mode == .message && model.phase == .working && !model.text.isEmpty
        let screen = targetScreen()
        let frame = screen.frame
        let notch = Self.notchRect(on: screen)
        let topInset = notch.height > 1 ? notch.height : 4
        let width: CGFloat
        let bodyHeight: CGFloat

        if model.mode == .list {
            width = min(max(460, appearance.menuFontSize * 36), frame.width - 40)
            bodyHeight = min(CGFloat(model.items.count) * Self.rowHeight(appearance.menuFontSize), frame.height * 0.45)
            model.scrolls = false
        } else {
            let font = NSFont.systemFont(ofSize: appearance.resultFontSize)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = appearance.lineSpacing
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
            let horizontal = appearance.paddingLeft + appearance.paddingRight
            let shown = model.text.isEmpty ? "Working…" : model.text
            let maximumWidth = min(appearance.maximumWidth, frame.width - 40)
            let minimumWidth = max(notch.width + 100, 320)
            let maximumBody = frame.height * 0.45
            // One width for every message, from "working" to the result: fitting it to each text made the popup
            // jump between narrow and wide while it was on screen. Lines therefore never rewrap while streaming.
            width = max(minimumWidth, maximumWidth)
            let textHeight: CGFloat
            if model.phase == .error || model.text.isEmpty {
                textHeight = ceil((shown as NSString).boundingRect(
                    with: NSSize(width: width - horizontal, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes).height) + 2
            } else {
                textHeight = measurer.height(of: model.text, width: width - horizontal,
                                             fontSize: appearance.resultFontSize, lineSpacing: appearance.lineSpacing) + 2
            }
            if streaming {
                streamedBodyHeight = max(streamedBodyHeight, min(textHeight, maximumBody))
                bodyHeight = streamedBodyHeight
            } else {
                bodyHeight = min(textHeight, maximumBody)
            }
            model.scrolls = textHeight > bodyHeight
        }
        // The label line above the text is 11 pt type, about 14 pt tall, followed by 6 pt of space.
        var noticeSpace: CGFloat = 0
        if model.mode == .message, let notice = model.notice {
            let noticeFont = NSFont.systemFont(ofSize: 12, weight: .medium)
            model.noticeHeight = ceil((notice as NSString).boundingRect(
                with: NSSize(width: width - appearance.paddingLeft - appearance.paddingRight, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: noticeFont]).height) + 2
            noticeSpace = model.noticeHeight + 6
        }
        let height = topInset + appearance.paddingTop + 14 + 6 + noticeSpace + bodyHeight + appearance.paddingBottom

        model.topInset = topInset
        model.contentWidth = width
        model.bodyHeight = bodyHeight

        let target = NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
        present(target, streaming: streaming)
        if demoFrameLog { Log.write("popup window \(panel.windowNumber) body height \(Int(bodyHeight))") }
    }

    /// The compact popup: as tall as the notch, the notch's width plus one side on each edge, wide enough for the
    /// action name (at most 150 pt). On a display without a notch it is a pill at the top centre.
    private func compactFrame() -> NSRect {
        let screen = targetScreen()
        let frame = screen.frame
        let notch = Self.notchRect(on: screen)
        let hasNotch = notch.height > 1
        let font = NSFont.systemFont(ofSize: Self.compactFontSize, weight: .medium)
        let labelWidth = ceil((model.compactLabel as NSString).size(withAttributes: [.font: font]).width) + 1
        // The three dots are about 21 pt wide; both sides get the same width, so the shape stays centred.
        let side = max(min(labelWidth, 150), 24)
        let height = hasNotch ? notch.height : 24
        let gap = hasNotch ? notch.width + 16 : 16
        model.compactSide = side
        model.compactGap = gap
        model.compactTopRadius = hasNotch ? 0 : height / 2
        model.compactBottomRadius = hasNotch ? 10 : height / 2
        model.compactClosedWidth = hasNotch ? notch.width : 0
        let width = gap + 2 * side + 2 * Self.compactPadding
        return NSRect(x: frame.midX - width / 2, y: frame.maxY - height - (hasNotch ? 0 : 4), width: width, height: height)
    }

    /// Puts the compact popup on screen: the window takes its final size at once and the black shape inside widens
    /// out of the notch. It has no shadow, like the notch itself.
    private func presentCompact(_ target: NSRect) {
        holdEscape(false)
        panel.hasShadow = false
        let wasVisible = visible
        visible = true
        panel.alphaValue = 1
        if panel.frame != target { panel.setFrame(target, display: true) }
        if wasVisible {
            model.compactOpen = true
            model.compactShown = true
        } else {
            model.compactOpen = false
            model.compactShown = false
            panel.orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in
                withAnimation(Self.compactOpening) { self?.model.compactOpen = true }
            }
            // The text comes in while the notch is still widening, not after it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.visible, self.model.compact else { return }
                withAnimation(.easeOut(duration: 0.14)) { self.model.compactShown = true }
            }
        }
    }

    static let compactOpening = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let compactClosing = Animation.easeIn(duration: 0.22)
    /// On closing, the text leaves over this time; the notch starts to narrow a little before it is gone.
    static let compactTextLeaving: TimeInterval = 0.16
    static let compactNarrowDelay: TimeInterval = 0.14

    /// Puts the popup at `target`: grows it out of the notch when it is not on screen yet, otherwise moves it.
    private func present(_ target: NSRect, streaming: Bool) {
        panel.hasShadow = true
        // While a full message is on screen, Esc closes it; the list handles Esc itself because it has the keyboard.
        // The compact popup leaves Esc to the person's application.
        holdEscape(model.mode == .message && !model.compact)
        if !visible {
            let notch = Self.notchRect(on: targetScreen())
            visible = true
            panel.setFrame(notch, display: false)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.25, 0.4, 1)
                panel.animator().setFrame(target, display: true)
            }
        } else if panel.frame != target {
            panel.alphaValue = 1
            NSAnimationContext.runAnimationGroup { context in
                // Streaming updates arrive every 50 ms; animating each of them makes the popup jitter, so they
                // apply at once (a zero-length animation also replaces an opening animation still in flight).
                context.duration = streaming ? 0 : 0.15
                panel.animator().setFrame(target, display: true)
            }
        }
        if demoFrameLog { Log.write("popup frame \(Int(target.minX)) \(Int(target.minY)) \(Int(target.width))x\(Int(target.height)) top=\(Int(target.maxY)) streaming=\(streaming)") }
    }

    private func targetScreen() -> NSScreen {
        let fallback = NSScreen.screens.first ?? NSScreen.main!
        switch screenChoice {
        case .notch:
            return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? fallback
        case .pointer:
            let point = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? fallback
        case .main:
            return fallback
        }
    }

    private static func notchRect(on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        var width: CGFloat = 200
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = frame.width - left.width - right.width
        }
        let height = max(screen.safeAreaInsets.top, 1)
        return NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
    }
}
