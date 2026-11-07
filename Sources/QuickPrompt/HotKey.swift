import Carbon

/// A system-wide keyboard shortcut registered through the Carbon hot key API.
/// It needs no permission and swallows the shortcut in every application.
final class HotKey {
    private static var registered: [UInt32: HotKey] = [:]
    private static var handlerInstalled = false
    private static var nextID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.id = Self.nextID
        Self.nextID += 1
        Self.installHandler()

        let hotKeyID = EventHotKeyID(signature: OSType(0x5154_524E), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { return nil }
        Self.registered[id] = self
    }

    /// Releases the shortcut so it can be registered again, for example after the actions file is reloaded.
    func invalidate() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        Self.registered[id] = nil
    }

    /// One handler for all shortcuts; it dispatches by the identifier of the pressed shortcut.
    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr, let hotKey = HotKey.registered[pressed.id] else { return noErr }
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
