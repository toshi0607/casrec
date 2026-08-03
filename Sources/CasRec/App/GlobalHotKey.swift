import Carbon

/// Registers ⌥⌘R with Carbon's application event target.  Unlike an NSEvent global monitor,
/// RegisterEventHotKey does not require the Input Monitoring TCC permission.
final class GlobalHotKey {
    private static let signature = OSType(0x4353_5243) // "CSRC"
    private static let identifier = UInt32(1)

    private let action: () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @discardableResult
    func register() -> Bool {
        guard hotKey == nil else { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else { return false }

        var registeredHotKey: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(optionKey | cmdKey),
            EventHotKeyID(signature: Self.signature, id: Self.identifier),
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard registerStatus == noErr else {
            if let eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
            return false
        }
        hotKey = registeredHotKey
        return true
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    fileprivate func handle(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard parameterStatus == noErr,
              hotKeyID.signature == Self.signature,
              hotKeyID.id == Self.identifier
        else {
            return OSStatus(eventNotHandledErr)
        }
        action()
        return noErr
    }

    deinit {
        unregister()
    }
}

private func globalHotKeyEventHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    return hotKey.handle(event)
}
